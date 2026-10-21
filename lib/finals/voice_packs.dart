import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../services/ai_settings.dart';
import '../services/user_profile.dart';
import 'voice_texts.dart';

/// Настройки сервиса озвучки (формат запроса — как у OpenAI `/v1/audio/speech`; его же понимают
/// многие совместимые сервисы и локальные серверы озвучки).
class VoiceConfig {
  final String url; // например https://api.openai.com/v1/audio/speech
  final String key;
  final String model;
  final String voice;
  final bool enabled;
  const VoiceConfig({required this.url, required this.key, required this.model, required this.voice, required this.enabled});

  bool get usable => enabled && url.startsWith('https://') && key.isNotEmpty;

  /// Подпись голоса: при смене сервиса/голоса записи делаются заново.
  String get signature => _hash('$url|$model|$voice');
}

String _hash(String s) {
  final d = SHA256Digest().process(Uint8List.fromList(utf8.encode(s)));
  return d.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Заранее готовые записи диктора финалов.
///
/// Общие (команды, числа) и именные («Лидирует {имя}», «Второй {имя}», «{имя}, четвёртое место»,
/// «Выбывает {имя}») создаются сервисом ИИ-озвучки заранее: при сохранении своего имени в анкете,
/// при смене имени бота и при добавлении чемпиона. В финале записи только проигрываются и
/// склеиваются, ожидания нет. Нет записи или сервиса — диктор говорит голосом телефона, как раньше.
class VoicePacks {
  VoicePacks._();

  static const _kUrl = 'finals_voice_url';
  static const _kModel = 'finals_voice_model';
  static const _kVoice = 'finals_voice_voice';
  static const _kOn = 'finals_voice_pack_on';

  /// Имена соперников-ботов по умолчанию (экран финалов); их записи готовятся вместе с общими.
  static const defaultBotNames = ['Бывалый', 'Татошка', 'Кость', 'Я в свое время тоже стрельбой занимался', 'Рыцарь', 'Сахарок', 'Усталый'];

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static const _kNames = 'finals_voice_names';

  /// Имена, для которых готовились именные записи (свои, боты, чемпионы) — для списка «по одной».
  static List<String> knownNames(LocalDbService db) {
    try {
      return [for (final n in jsonDecode(_get(db, _kNames) ?? '[]') as List) '$n'];
    } catch (_) {
      return [];
    }
  }

  static void _rememberNames(LocalDbService db, Iterable<String> names) {
    final all = {...knownNames(db), for (final n in names) VoiceTexts.spokenName(n)}..remove('');
    _put(db, _kNames, jsonEncode(all.toList()));
  }

  static String urlOverride(LocalDbService db) => _get(db, _kUrl) ?? '';
  static bool enabled(LocalDbService db) => _get(db, _kOn) == '1';

  /// Озвучка моделью работает только со своим ключом ИИ (настройки ИИ → «Свой ключ»): ключ и
  /// адрес берутся оттуда, адрес озвучки — `<адрес ИИ>/audio/speech`, если не задан свой.
  static VoiceConfig config(LocalDbService db) {
    final ai = AiSettings(db);
    final own = ai.hasOwnKey;
    final custom = urlOverride(db).trim();
    final base = ai.apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return VoiceConfig(
      url: custom.isNotEmpty ? custom : (own ? '$base/audio/speech' : ''),
      key: own ? ai.apiKey : '',
      model: _get(db, _kModel) ?? 'tts-1',
      voice: _get(db, _kVoice) ?? 'alloy',
      enabled: enabled(db) && own,
    );
  }

  static void saveSettings(LocalDbService db, {required String model, required String voice, required String urlOverride, required bool enabled}) {
    _put(db, _kUrl, urlOverride.trim());
    _put(db, _kModel, model.trim().isEmpty ? 'tts-1' : model.trim());
    _put(db, _kVoice, voice.trim().isEmpty ? 'alloy' : voice.trim());
    _put(db, _kOn, enabled ? '1' : '0');
  }

  static bool get supported => !kIsWeb;

  /// Ход подготовки записей: null — не идёт. (сделано, всего, последняя ошибка)
  static final status = ValueNotifier<({int done, int total, String? error})?>(null);

  static Directory? _rootDir;

  @visibleForTesting
  static void useRootForTest(Directory d) => _rootDir = d;
  static Future<Directory> _root() async => _rootDir ??= Directory(p.join((await getApplicationSupportDirectory()).path, 'voice'));

  static String _lang() => VoiceTexts.langFor(I18n.code);

  /// Файл записи для ссылки (`num_100`, `cmd_stop` или `name:<шаблон>:<имя>`).
  static Future<File> fileFor(VoiceConfig c, String lang, String ref) async {
    final dir = p.join((await _root()).path, lang, c.signature);
    if (ref.startsWith('name:')) {
      final parts = ref.split(':');
      final tmpl = parts[1];
      final name = parts.sublist(2).join(':');
      return File(p.join(dir, 'n_${_hash(name.toLowerCase())}_$tmpl.mp3'));
    }
    return File(p.join(dir, '$ref.mp3'));
  }

  // ---------------- генерация ----------------

  /// Один запрос к сервису озвучки. `null` — не получилось.
  static Future<Uint8List?> synthesize(VoiceConfig c, String text, {http.Client Function()? clientFactory}) async {
    final client = (clientFactory ?? http.Client.new)();
    try {
      final res = await client
          .post(
            Uri.parse(c.url),
            headers: {'Authorization': 'Bearer ${c.key}', 'Content-Type': 'application/json'},
            body: jsonEncode({'model': c.model, 'voice': c.voice, 'input': text, 'response_format': 'mp3'}),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode >= 300 || res.bodyBytes.length < 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static bool _busy = false;

  /// Готовит недостающие записи: [items] — ссылка → текст. Уже существующие пропускаются.
  static Future<int> _ensureItems(VoiceConfig c, String lang, Map<String, String> items, {http.Client Function()? clientFactory}) async {
    var made = 0;
    final todo = <String, String>{};
    for (final e in items.entries) {
      if (!await (await fileFor(c, lang, e.key)).exists()) todo[e.key] = e.value;
    }
    if (todo.isEmpty) return 0;
    var done = 0;
    String? lastError;
    status.value = (done: 0, total: todo.length, error: null);
    for (final e in todo.entries) {
      Uint8List? bytes;
      for (var attempt = 0; attempt < 2 && bytes == null; attempt++) {
        bytes = await synthesize(c, e.value, clientFactory: clientFactory);
      }
      if (bytes == null) {
        lastError = 'Сервис озвучки не ответил на «${e.value}»';
      } else {
        final f = await fileFor(c, lang, e.key);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
        made++;
      }
      done++;
      status.value = (done: done, total: todo.length, error: lastError);
    }
    Timer(const Duration(seconds: 4), () => status.value = null);
    return made;
  }

  static Map<String, String> _namedItems(String lang, String name) =>
      {for (final e in VoiceTexts.namedTexts(lang, name).entries) VoiceTexts.namedRef(e.key, name): e.value};

  /// Записи для имён (участник или бот); «(Bot)» в озвучке отбрасывается.
  static Future<int> ensureNames(LocalDbService db, Iterable<String> names, {http.Client Function()? clientFactory}) async {
    final c = config(db);
    if (!supported || !c.usable || _busy) return 0;
    _busy = true;
    try {
      final lang = _lang();
      final items = <String, String>{};
      for (final n in names) {
        final s = VoiceTexts.spokenName(n);
        if (s.isNotEmpty) items.addAll(_namedItems(lang, s));
      }
      _rememberNames(db, names);
      return await _ensureItems(c, lang, items, clientFactory: clientFactory);
    } finally {
      _busy = false;
    }
  }

  /// Всё нужное: общие записи, своё имя из анкеты и имена ботов по умолчанию.
  static Future<int> ensureAll(LocalDbService db, {http.Client Function()? clientFactory}) async {
    final c = config(db);
    if (!supported || !c.usable || _busy) return 0;
    _busy = true;
    try {
      final lang = _lang();
      final items = <String, String>{...VoiceTexts.common(lang)};
      final names = [ownName(db), ...defaultBotNames];
      for (final n in names) {
        final s = VoiceTexts.spokenName(n);
        if (s.isNotEmpty) items.addAll(_namedItems(lang, s));
      }
      _rememberNames(db, names);
      return await _ensureItems(c, lang, items, clientFactory: clientFactory);
    } finally {
      _busy = false;
    }
  }

  static String ownName(LocalDbService db) => '${UserProfile.firstNameOf(db)} ${UserProfile.lastNameOf(db)}'.trim();

  /// Имя в анкете сохранено или изменено: старые записи убираем, новые готовим в фоне.
  static void onProfileChanged(LocalDbService db, {String oldName = ''}) {
    if (!supported || !config(db).usable) return;
    final now = ownName(db);
    unawaited(() async {
      if (oldName.trim().isNotEmpty && oldName.trim() != now) await forgetName(db, oldName);
      await ensureAll(db);
    }());
  }

  /// Имя бота изменено или добавлен чемпион: прежние записи имени удаляются, новые готовятся.
  static void onOpponentRenamed(LocalDbService db, {String? oldName, required String newName}) {
    if (!supported || !config(db).usable) return;
    unawaited(() async {
      if (oldName != null && oldName != newName && !defaultBotNames.contains(VoiceTexts.spokenName(oldName))) {
        await forgetName(db, oldName);
      }
      await ensureNames(db, [newName]);
    }());
  }

  /// Удаляет все именные записи имени (всех языков и голосов).
  static Future<void> forgetName(LocalDbService db, String name) async {
    final s = VoiceTexts.spokenName(name);
    if (s.isEmpty) return;
    _put(db, _kNames, jsonEncode(knownNames(db).where((n) => n != s).toList()));
    final prefix = 'n_${_hash(s.toLowerCase())}_';
    try {
      final root = await _root();
      if (!await root.exists()) return;
      await for (final e in root.list(recursive: true)) {
        if (e is File && p.basename(e.path).startsWith(prefix)) await e.delete();
      }
    } catch (_) {}
  }

  // ---------------- по одной записи ----------------

  /// Группы записей для экрана «по одной»: общие и по каждому имени: (название, [(ссылка, текст)]).
  static List<(String, List<(String, String)>)> groups(LocalDbService db) {
    final lang = _lang();
    final out = <(String, List<(String, String)>)>[
      (tr('Общие (команды и числа)'), [for (final e in VoiceTexts.common(lang).entries) (e.key, e.value)]),
    ];
    final names = <String>{ownName(db), ...defaultBotNames, ...knownNames(db)}..remove('');
    for (final n in names) {
      final spoken = VoiceTexts.spokenName(n);
      if (spoken.isEmpty) continue;
      out.add((spoken, [for (final e in _namedItems(lang, spoken).entries) (e.key, e.value)]));
    }
    return out;
  }

  static Future<bool> clipExists(LocalDbService db, String ref) async {
    final c = config(db);
    return supported && c.usable && await (await fileFor(c, _lang(), ref)).exists();
  }

  /// Озвучивает ОДНУ запись заново (перезаписывает файл) — остальные не трогаются, лишнего трафика нет.
  static Future<bool> regenerate(LocalDbService db, String ref, String text, {http.Client Function()? clientFactory}) async {
    final c = config(db);
    if (!supported || !c.usable) return false;
    final bytes = await synthesize(c, text, clientFactory: clientFactory);
    if (bytes == null) return false;
    final f = await fileFor(c, _lang(), ref);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return true;
  }

  static Future<void> deleteClip(LocalDbService db, String ref) async {
    final f = await fileFor(config(db), _lang(), ref);
    if (await f.exists()) await f.delete();
  }

  /// Удаляет все записи (смена сервиса, очистка места).
  static Future<void> clearAll() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
  }

  // ---------------- воспроизведение ----------------

  static AudioPlayer? _player;
  static Future<void> _chain = Future.value();
  static int _gen = 0;

  /// Все записи [refs] есть на устройстве.
  static Future<bool> canPlay(LocalDbService db, List<String> refs) async {
    final c = config(db);
    if (!supported || !c.usable || refs.isEmpty) return false;
    final lang = _lang();
    for (final r in refs) {
      final ref = r.startsWith('name:') ? _spokenRef(r) : r;
      if (!await (await fileFor(c, lang, ref)).exists()) return false;
    }
    return true;
  }

  static String _spokenRef(String ref) {
    final parts = ref.split(':');
    return 'name:${parts[1]}:${VoiceTexts.spokenName(parts.sublist(2).join(':'))}';
  }

  /// Проигрывает записи подряд (склейка). [queue] — встать в очередь за уже звучащим.
  /// `false` — каких-то записей нет, ничего не проиграно (вызывающий говорит голосом телефона).
  static Future<bool> play(LocalDbService db, List<String> refs, {bool queue = true}) async {
    if (!await canPlay(db, refs)) return false;
    final c = config(db);
    final lang = _lang();
    if (!queue) await stop();
    final myGen = _gen;
    _chain = _chain.then((_) async {
      for (final r in refs) {
        if (myGen != _gen) return;
        try {
          final f = await fileFor(c, lang, r.startsWith('name:') ? _spokenRef(r) : r);
          final player = _player ??= AudioPlayer();
          final done = Completer<void>();
          final sub = player.onPlayerComplete.listen((_) {
            if (!done.isCompleted) done.complete();
          });
          await player.play(DeviceFileSource(f.path));
          await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
          await sub.cancel();
        } catch (_) {}
      }
    });
    return true;
  }

  static Future<void> stop() async {
    _gen++;
    try {
      await _player?.stop();
    } catch (_) {}
    _chain = Future.value();
  }
}
