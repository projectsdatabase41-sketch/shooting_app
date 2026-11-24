import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../finals/voice_packs.dart' show VoicePacks;
import '../finals/voice_texts.dart' show VoiceTexts;
import '../i18n/i18n.dart';
import 'local_db_service.dart';

/// Запись каталога готовых пакетов озвучки (assets/voice/voice_catalog.json).
/// Владелец 24.11: пакеты готовы локально и будут залиты на Google Диск;
/// пока `driveId` пуст, пакет числится «недоступен» — код это не ломает.
class VoiceCatalogEntry {
  final String lang;
  final String file;
  final int bytes;
  final int phrases;

  /// Id файла на Google Drive; `null` — файл ещё не залит (в списке «недоступен»).
  final String? driveId;
  const VoiceCatalogEntry(this.lang, this.file, this.bytes, this.phrases, this.driveId);
}

/// Состояние пакета для списка в модуле озвучки.
enum VoicePackState { notDownloaded, downloaded, unavailable }

/// Хранилище готовых пакетов озвучки финалов (модуль «Озвучка», владелец 24.11):
/// каталог из ассета, скачивание по `driveId` с Google Drive в каталог
/// приложения `<appSupport>/voice_packs/<lang>/`, распаковка zip (пакет
/// `archive` уже есть в pubspec — новых зависимостей не добавляем), проверка
/// и удаление. Прогресс — [progress], статусы — [status].
class VoicePackStore {
  VoicePackStore._();

  // ---------------- движок озвучки ----------------

  /// Выбор движка в модуле озвучки («Озвучка в реальном времени с помощью ИИ и
  /// своего ключа» / «машинная озвучка» / «готовый пакет»); читается в
  /// FinalsAnnouncer, чтобы финал сразу использовал выбранное:
  /// - [enginePackage] — готовый скачанный пакет (wav), при нехватке фраз — ИИ,
  ///   затем TTS телефона;
  /// - [engineAi] — озвучка ИИ в реальном времени своим ключом (прежнее поведение);
  /// - [engineTts] — машинная озвучка голосом телефона.
  static const enginePackage = 'package';
  static const engineAi = 'ai';
  static const engineTts = 'tts';

  static const _kEngine = 'voice_engine';

  /// По умолчанию `ai`: это в точности прежняя цепочка «ИИ своим ключом → TTS»,
  /// у кого озвучка уже была настроена — ничего не меняется.
  static String engineOf(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_kEngine]);
    final v = rows.isEmpty ? null : '${rows.first['hex']}';
    if (v == enginePackage || v == engineTts || v == engineAi) return v!;
    return engineAi;
  }

  static void setEngine(LocalDbService db, String engine) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [_kEngine, engine],
    );
  }

  // ---------------- каталог ----------------

  static const _catalogAsset = 'assets/voice/voice_catalog.json';

  static final _catalog = ValueNotifier<List<VoiceCatalogEntry>>(const []);
  static bool get catalogLoaded => _catalog.value.isNotEmpty;
  static List<VoiceCatalogEntry> get catalog => List.unmodifiable(_catalog.value);

  static VoiceCatalogEntry? entryFor(String lang) {
    for (final e in _catalog.value) {
      if (e.lang == lang) return e;
    }
    return null;
  }

  /// Название языка для списка (словари имён уже есть у I18n — второй список не заводим).
  static String languageName(String lang) {
    if (lang == 'ru') return 'Русский';
    return I18n.builtIn[lang] ?? I18n.downloadable[lang] ?? lang;
  }

  /// Читает каталог из ассета. При ошибке каталог остаётся пустым: экран
  /// покажет «недоступен». Сети тут нет — ассет вшит в сборку, бросать
  /// наверх нечего.
  static Future<void> loadCatalog() async {
    if (catalogLoaded) return;
    try {
      final raw = await rootBundle.loadString(_catalogAsset);
      final data = jsonDecode(raw);
      final list = <VoiceCatalogEntry>[];
      if (data is Map && data['packs'] is List) {
        for (final m in data['packs'] as List) {
          if (m is! Map) continue;
          final lang = '${m['lang']}';
          if (lang.isEmpty || lang == 'null') continue;
          final drive = m['driveId'];
          list.add(VoiceCatalogEntry(
            lang,
            '${m['file'] ?? '$lang.zip'}',
            m['bytes'] is num ? (m['bytes'] as num).toInt() : 0,
            m['phrases'] is num ? (m['phrases'] as num).toInt() : 0,
            drive == null || '$drive'.isEmpty || '$drive' == 'null' ? null : '$drive',
          ));
        }
      }
      if (list.isNotEmpty) _catalog.value = list;
    } catch (_) {
      // Битый ассет или его нет в сборке: статусы не строим, пакеты недоступны.
    }
    unawaited(refreshStatuses());
  }

  // ---------------- файлы на устройстве ----------------

  static Directory? _rootDir;

  @visibleForTesting
  static void useRootForTest(Directory d) => _rootDir = d;
  static Future<Directory> _root() async =>
      _rootDir ??= Directory(p.join((await getApplicationSupportDirectory()).path, 'voice_packs'));

  static Future<Directory> packDir(String lang) async {
    return Directory(p.join((await _root()).path, lang));
  }

  static Future<bool> isDownloaded(String lang) async => (await _keys(lang)) != null;

  /// Ключи фраз скачанного пакета из manifest.json (`cmd_*`, `int_*`, `ten_*`,
  /// `bot_*`). null — пакета нет или манифест не читается. Кэшируется:
  /// announcer спрашивает это на каждой команде финала.
  static final Map<String, Set<String>?> _keysCache = {};

  static Future<Set<String>?> _keys(String lang) async {
    if (_keysCache.containsKey(lang)) return _keysCache[lang];
    Set<String>? keys;
    try {
      final dir = await packDir(lang);
      final f = File(p.join(dir.path, 'manifest.json'));
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString());
        final items = data is Map && data['items'] is Map ? data['items'][lang] : null;
        if (items is Map && items.isNotEmpty) {
          keys = {for (final k in items.keys) '$k'};
        }
      }
    } catch (_) {
      keys = null;
    }
    _keysCache[lang] = keys;
    return keys;
  }

  static void _forgetKeys(String lang) => _keysCache.remove(lang);

  /// Файл записи пакета (`cmd_stop.wav`…): есть и манифест знает ключ.
  static Future<File?> wavFor(String lang, String key) async {
    final keys = await _keys(lang);
    if (keys == null || !keys.contains(key)) return null;
    final f = File(p.join((await packDir(lang)).path, '$key.wav'));
    return await f.exists() ? f : null;
  }

  // ---------------- статусы ----------------

  /// Статусы пакетов по языкам (для списка модуля).
  static final status = ValueNotifier<Map<String, VoicePackState>>({});

  /// Прогресс скачивания по языкам (получено/всего байт); запись убирается по завершении.
  static final progress = ValueNotifier<Map<String, ({int received, int total})>>({});

  static bool isDownloading(String lang) => progress.value.containsKey(lang);

  static void _setStatus(String lang, VoicePackState st) {
    status.value = {...status.value, lang: st};
  }

  /// Перечитывает статус каждого пакета каталога (открытие экрана, после
  /// скачивания и удаления).
  static Future<void> refreshStatuses() async {
    final map = <String, VoicePackState>{};
    for (final e in _catalog.value) {
      map[e.lang] = await isDownloaded(e.lang)
          ? VoicePackState.downloaded
          : (e.driveId == null ? VoicePackState.unavailable : VoicePackState.notDownloaded);
    }
    status.value = map;
  }

  // ---------------- скачивание и распаковка ----------------

  static final _busy = <String>{};

  /// Скачивает и распаковывает пакет языка. Возвращает null — успех, иначе
  /// понятный текст ошибки (без адресов и ключей: в интерфейсе их не показываем).
  static Future<String?> download(String lang) async {
    final entry = entryFor(lang);
    if (entry == null) return tr('Для этого языка нет пакета');
    if (entry.driveId == null || entry.driveId!.isEmpty) {
      _setStatus(lang, VoicePackState.unavailable);
      return tr('Пакет ещё не выложен на диск — недоступен');
    }
    if (_busy.contains(lang)) return null;
    _busy.add(lang);
    try {
      final bytes = await _fetchZip(lang, entry.driveId!);
      if (bytes == null) {
        _setStatus(lang, VoicePackState.unavailable);
        return tr('Не удалось скачать пакет: нет связи с диском');
      }
      if (bytes.length < 100 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
        // Подписи «PK» нет — Drive отдал страницу вместо файла; повтор
        // с формой уже сделан, значит ссылка ведёт не на пакет.
        _setStatus(lang, VoicePackState.unavailable);
        return tr('Файл пакета повреждён — попробуйте скачать ещё раз');
      }
      progress.value = {...progress.value, lang: (received: bytes.length, total: bytes.length)};
      // Распаковка в изоляте: 17 МБ zip на слабом телефоне не должны
      // замораживать интерфейс при вводе финала.
      Map<String, Uint8List> files;
      try {
        files = await compute(_extractZip, bytes);
      } catch (_) {
        files = const {};
      }
      if (files.isEmpty) {
        _setStatus(lang, VoicePackState.unavailable);
        return tr('Файл пакета повреждён — попробуйте скачать ещё раз');
      }
      // Сначала во временную папку: пакет, оборванный при распаковке,
      // не должен остаться «скачанным». Из архива берём только имена файлов —
      // ничего не пишется за пределами папки пакета.
      final tmp = Directory(p.join((await _root()).path, '_tmp_${lang}_${DateTime.now().millisecondsSinceEpoch}'));
      try {
        await tmp.create(recursive: true);
        for (final e in files.entries) {
          final name = p.basename(e.key);
          if (name.isEmpty || name == '.') continue;
          await File(p.join(tmp.path, name)).writeAsBytes(e.value);
        }
        final dir = await packDir(lang);
        if (await dir.exists()) await dir.delete(recursive: true);
        await tmp.rename(dir.path);
      } on FileSystemException {
        try {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        } catch (_) {}
        return tr('Не хватило места на устройстве — пакет не распакован');
      }
      _forgetKeys(lang);
      final ok = await _keys(lang) != null;
      _setStatus(lang, ok ? VoicePackState.downloaded : VoicePackState.unavailable);
      return ok ? null : tr('Файл пакета повреждён — попробуйте скачать ещё раз');
    } finally {
      _busy.remove(lang);
      final pr = {...progress.value}..remove(lang);
      progress.value = pr;
    }
  }

  static Future<void> delete(String lang) async {
    try {
      final dir = await packDir(lang);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _forgetKeys(lang);
    final entry = entryFor(lang);
    _setStatus(lang, entry == null || entry.driveId == null
        ? VoicePackState.unavailable
        : VoicePackState.notDownloaded);
  }

  /// Проверка пакета: все записи манифеста на месте и не пустые. null — всё
  /// хорошо, иначе понятный текст (без путей).
  static Future<String?> verify(String lang) async {
    final keys = await _keys(lang);
    if (keys == null) return tr('Пакет не скачан или повреждён');
    final dir = await packDir(lang);
    var bad = 0;
    for (final k in keys) {
      final f = File(p.join(dir.path, '$k.wav'));
      if (!await f.exists()) {
        bad++;
      } else if (await f.length() == 0) {
        bad++;
      }
    }
    return bad == 0
        ? tr('Всё на месте: {n} записей', {'n': keys.length})
        : tr('Не хватает {n} записей — скачайте пакет заново', {'n': bad});
  }

  /// Качает zip потоком с прогрессом. Drive на большие файлы может отдать
  /// страницу подтверждения вместо файла — тогда один раз повторяем с
  /// полями её формы (confirm/uuid), это обычный сценарий публичных ссылок.
  static Future<Uint8List?> _fetchZip(String lang, String driveId) async {
    final client = http.Client();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final res = await client
            .send(http.Request('GET', Uri.parse(_downloadUrl(driveId))))
            .timeout(const Duration(seconds: 60));
        if (res.statusCode >= 300) return null;
        final ct = res.headers['content-type'] ?? '';
        final total = res.contentLength ?? 0;
        final chunks = BytesBuilder(copy: false);
        await for (final chunk in res.stream) {
          chunks.add(chunk);
          if (!ct.contains('text/html')) {
            progress.value = {
              ...progress.value,
              lang: (received: chunks.length, total: total > 0 ? total : chunks.length),
            };
          }
        }
        final bytes = chunks.takeBytes();
        final looksHtml = ct.contains('text/html') || (bytes.length < 4096 && bytes.isNotEmpty && bytes[0] == 0x3C);
        if (!looksHtml) return bytes;
        if (attempt == 1) return null; // и второй раз страница — ссылки с файлом нет
        final fields = _hiddenInputs(utf8.decode(bytes, allowMalformed: true));
        if (fields.isEmpty) return null;
        _downloadUrlConfirm = fields;
      }
      return null;
    } catch (_) {
      // Сеть, таймаут, редирект-цикл — наружу один понятный текст (см. download).
      return null;
    } finally {
      client.close();
    }
  }

  /// Поля формы подтверждения Drive, собранные на предыдущем шаге.
  static Map<String, String> _downloadUrlConfirm = const {};

  static String _downloadUrl(String driveId) {
    final params = {'id': driveId, 'export': 'download'};
    return Uri.parse('https://drive.usercontent.google.com/download')
        .replace(queryParameters: {...params, ..._downloadUrlConfirm})
        .toString();
  }

  static Map<String, String> _hiddenInputs(String html) {
    final out = <String, String>{};
    final tagRe = RegExp(r'<input[^>]*>', caseSensitive: false);
    final nameRe = RegExp(r'name\s*=\s*"([^"]*)"', caseSensitive: false);
    // Значение поля бывает в двойных и в одинарных кавычках — два выражения
    // (в raw-строках Dart кавычки-ограничители не экранируются).
    final valueDq = RegExp(r'value\s*=\s*"([^"]*)"', caseSensitive: false);
    final valueSq = RegExp(r"value\s*=\s*'([^']*)'", caseSensitive: false);
    for (final m in tagRe.allMatches(html)) {
      final tag = m.group(0)!;
      final n = nameRe.firstMatch(tag)?.group(1);
      if (n == null || n.isEmpty) continue;
      final vm = valueDq.firstMatch(tag) ?? valueSq.firstMatch(tag);
      out[n] = vm?.group(1) ?? '';
    }
    return out;
  }

  // ---------------- сопоставление фраз пакета ссылкам финала ----------------

  /// Готовит ключи пакета для списка ссылок озвучки. null — хоть одна фраза
  /// не воспроизводится готовой записью, вызывающий уходит по цепочке
  /// fallback (ИИ своим ключом → TTS телефона).
  ///
  /// Ссылки финала (см. voice_texts.dart) переводятся в ключи манифеста:
  /// - `cmd_*` — совпадают напрямую;
  /// - цепочка счёта «105,3» = [num_100, num_005, num_comma, num_003] — в пакете
  ///   числа произносятся как «сто пять целых, три десятых»: собираем целую часть
  ///   из num_* до запятой в `int_105`, десятую — в `ten_3` (счёт финала до 300);
  /// - `name:<шаблон>:<имя>` — `bot_<шаблон>_<i>` по именам ботов по умолчанию
  ///   (пакет сгенерирован ровно под них); своё имя — уже ИИ-озвучка.
  static Future<List<String>?> packKeysFor(String lang, List<String> refs) async {
    if (refs.isEmpty) return null;
    if (await _keys(lang) == null) return null;
    final keys = <String>[];
    final intParts = <int>[];
    int? tenths;
    var fail = false;

    // Накопленная цепочка счёта → int_* + ten_* (число всегда кончается запятой и десятой).
    void flushNumber() {
      if (fail || (intParts.isEmpty && tenths == null)) return;
      if (tenths == null) {
        fail = true;
        return;
      }
      final total = intParts.fold(0, (a, b) => a + b);
      if (total > 300) {
        fail = true; // счёт финала до 300, больших записей в пакете нет
        return;
      }
      if (total > 0) keys.add('int_${total.toString().padLeft(3, '0')}');
      keys.add('ten_$tenths');
      intParts.clear();
      tenths = null;
    }

    for (final ref in refs) {
      if (fail) break;
      if (ref.startsWith('num_')) {
        if (ref == 'num_comma') continue; // разделитель: целые до, десятая после
        final v = int.tryParse(ref.substring(4));
        if (v == null) {
          fail = true;
        } else if (tenths == null) {
          intParts.add(v);
        } else {
          tenths = v;
        }
      } else if (ref.startsWith('name:')) {
        flushNumber();
        final parts = ref.split(':');
        final idx = VoicePacks.defaultBotNames.indexOf(VoiceTexts.spokenName(parts.sublist(2).join(':')));
        if (idx < 0) {
          fail = true; // своё имя или нестандартный соперник — готовой записи нет
          break;
        }
        keys.add('bot_${parts[1]}_$idx');
      } else {
        flushNumber();
        keys.add(ref); // команды cmd_* и будущие int_/ten_ ключи — напрямую
      }
    }
    flushNumber();
    if (fail) return null;
    for (final k in keys) {
      if (await wavFor(lang, k) == null) return null;
    }
    return keys.isEmpty ? null : keys;
  }

  // ---------------- воспроизведение ----------------

  static AudioPlayer? _player;
  static Future<void> _chain = Future.value();
  static int _gen = 0;

  /// Проигрывает записи пакета подряд. false — не получилось (вызывающий
  /// уходит по цепочке fallback: ИИ своим ключом → TTS телефона).
  static Future<bool> play(String lang, List<String> keys, {bool queue = true}) async {
    for (final k in keys) {
      if (await wavFor(lang, k) == null) return false;
    }
    if (!queue) await stop();
    final myGen = _gen;
    _chain = _chain.then((_) async {
      for (final k in keys) {
        if (myGen != _gen) return;
        try {
          final path = (await wavFor(lang, k))!.path;
          final player = _player ??= AudioPlayer();
          final done = Completer<void>();
          final sub = player.onPlayerComplete.listen((_) {
            if (!done.isCompleted) done.complete();
          });
          await player.play(DeviceFileSource(path));
          await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
          await sub.cancel();
        } catch (_) {
          // Сбой на одном файле не обрывает остальную склейку.
        }
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

/// Распаковка zip в изоляте: путь в архиве → байты. manifest.json лежит
/// в корне, wav — в папке `<lang>/`; раскладкой по папкам пакета занимается
/// [VoicePackStore.download]. Топ-уровневая функция — требование compute.
Map<String, Uint8List> _extractZip(Uint8List bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final out = <String, Uint8List>{};
    for (final file in archive.files) {
      if (file.isFile) out[file.name] = file.content;
    }
    return out;
  } catch (_) {
    return const {};
  }
}
