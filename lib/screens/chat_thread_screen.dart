import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../logic/adaptive_poller.dart';
import '../logic/ai_context.dart';
import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../services/call_session.dart';
import '../services/ai_settings.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_presence.dart';
import '../services/chat_sync_service.dart';
import '../services/chat_translation_service.dart';
import '../services/live_chat_session.dart';
import '../services/remote_config.dart';
import '../services/webrtc_peer_link.dart';
import '../state/app_data_store.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/chat_quick_menu.dart';
import '../widgets/chat_reply_bar.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import 'attachment_compose_screen.dart';
import 'call_screen.dart';
import 'chat_contact_panel_screen.dart';
import 'chat_home_screen.dart';
import 'photo_viewer_screen.dart';

/// Переписка с одним контактом. Открытие ветки сразу отмечает входящие
/// прочитанными локально (сервер их к этому моменту уже не хранит — см.
/// `ChatSyncService.pollIncoming`).
class ChatThreadScreen extends StatefulWidget {
  final ChatContact contact;
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;

  const ChatThreadScreen({
    super.key,
    required this.contact,
    required this.auth,
    required this.repo,
    required this.sync,
    required this.prefs,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  late ChatContact _contact = widget.contact;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  PollLoop? _pollLoop;
  LiveChatSession? _live;
  List<ChatMessage> _messages = [];
  bool _sending = false;
  bool _aiBusy = false;

  /// График от ИИ, ждущий отправки (показывается над полем ввода).
  Map<String, dynamic>? _pendingChart;
  ChatMessage? _replyingTo;

  /// Кнопка "вниз к недавним" — появляется, когда прокрутили далеко
  /// вверх по истории. Отдельный notifier, а не setState: прокрутка не
  /// должна перестраивать всю ленту.
  final _showJumpToEnd = ValueNotifier(false);

  /// Панель смайликов вместо системной клавиатуры.
  bool _emojiOpen = false;
  final _inputFocus = FocusNode();

  /// Высота плавающей нижней панели — лента получает такой отступ снизу,
  /// чтобы последнее сообщение не пряталось под полем ввода.
  final _barKey = GlobalKey();
  double _barHeight = 72;

  /// Множественное выделение — долгое нажатие сразу выделяет сообщение,
  /// дальше обычный тап по другим добавляет/убирает их из набора.
  /// Копировать/перевести/удалить работают на весь набор; ответить/
  /// редактировать/повторить — только когда выбрано ровно одно (один
  /// reply на сообщение в модели данных, не список).
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;
  void _toggleSelect(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  /// Переводы по id сообщения — только в памяти экрана, не сохраняются:
  /// дешевле перевести заново, чем городить локальное хранилище ради
  /// текста, который и так живёт на устройстве получателя.
  final Map<String, String> _translations = {};
  final Set<String> _translating = {};

  /// Сообщения, перевод которых упал с ошибкой — текст ошибки, чтобы
  /// показать по тапу на красный значок. Без этого списка автоперевод
  /// бесконечно повторял попытку на каждый `_reload()`/опрос сервера для
  /// сообщения, которое в принципе не переводится (лишняя сетевая
  /// нагрузка при сотнях сообщений выглядела как "зависание").
  final Map<String, String> _translationErrors = {};

  /// "Маска" — показывать ли перевод ВМЕСТО оригинала (пункт из
  /// обсуждения). Явный выбор пользователя по конкретному сообщению
  /// (кнопка "Перевести" в меню — тумблер, а не одноразовое действие);
  /// пока выбора нет, действует умолчание режима: в "всегда автоматически"
  /// маска на входящих включена сама, в "по кнопке" — выключена.
  final Map<String, bool> _maskOverride = {};
  late final ChatTranslationService _translator = ChatTranslationService();

  /// Автоперевод грузит только "хвост" списка (последние сообщения),
  /// не всю историю сразу — иначе сотни сообщений сразу шлют сотни
  /// запросов к переводчику. Прокрутка к началу подгружает следующую
  /// пачку (решение пользователя).
  int _translateVisibleCount = 15;
  int _translateLoads = 0;
  bool get _autoOn => widget.prefs.autoTranslateFor(_contact.id);
  String _lastTranslationLanguage = '';

  bool _isMasked(ChatMessage m) {
    final override = _maskOverride[m.id];
    if (override != null) return override;
    return _autoOn && m.direction == ChatMessageDirection.incoming && _translations.containsKey(m.id);
  }

  @override
  void initState() {
    super.initState();
    _lastTranslationLanguage = widget.prefs.translationLanguage;
    widget.prefs.addListener(_onPrefsChanged);
    widget.repo.markThreadSeen(_contact.id);
    widget.sync.reportRead(_contact.id);
    _reload();
    _scroll.addListener(_onScroll);
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus && _emojiOpen) setState(() => _emojiOpen = false);
    });
    // Живой канал (WebSocket) — включается удалённо, по умолчанию выключен.
    if (!_contact.isGroup) {
      _live = LiveChatSession(
        auth: widget.auth,
        repo: widget.repo,
        contactId: _contact.id,
        linkFactory: WebRtcPeerLink.new,
        onIncoming: () {
          if (!mounted) return;
          widget.repo.markThreadSeen(_contact.id);
          widget.sync.reportRead(_contact.id);
          _reload();
          _scrollToEnd();
        },
      );
      widget.sync.live = _live;
      _live!.open();
    }
    // Адаптивный опрос: пока собеседник пишет — каждые 5 секунд, в тишине
    // растёт до 30 (см. AdaptivePoller). Отправка своего сообщения возвращает
    // частый режим — ответ обычно приходит скоро.
    _pollLoop = PollLoop(
      poller: AdaptivePoller(
          min: const Duration(seconds: 5),
          max: const Duration(seconds: 30),
          scale: () => RemoteConfig.pollScale * (_live?.peerOnline == true ? 4 : 1)),
      tick: () async {
        final added = await widget.sync.pollIncoming();
        if (added > 0 && mounted) {
          widget.repo.markThreadSeen(_contact.id);
          widget.sync.reportRead(_contact.id);
          _reload();
          _scrollToEnd();
        }
        return added > 0;
      },
    )..start();
    _pollLoop!.poke(); // открыли диалог — сразу забираем то, что лежит в базе
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefsChanged);
    _pollLoop?.stop();
    if (widget.sync.live == _live) widget.sync.live = null;
    _live?.close();
    _input.dispose();
    _scroll.dispose();
    _showJumpToEnd.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Смена языка перевода в настройках — старые переводы сделаны на
  /// прежний язык, маска с ними бессмысленна (решение пользователя):
  /// сбрасываем кэш и переводим заново.
  void _onPrefsChanged() {
    if (!mounted) return;
    if (widget.prefs.translationLanguage != _lastTranslationLanguage) {
      _lastTranslationLanguage = widget.prefs.translationLanguage;
      setState(() {
        _translations.clear();
        _maskOverride.clear();
        _translationErrors.clear();
      });
      if (_autoOn) _autoTranslateIncoming();
    } else {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Лента перевёрнута (reverse): 0 — самые новые внизу экрана.
    _showJumpToEnd.value = _scroll.position.pixels > 400;
    if (_translateVisibleCount >= _messages.length) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      // Последние 15, листаем выше — ещё 20, дальше — по 30 (решение пользователя).
      _translateVisibleCount += _translateLoads++ == 0 ? 20 : 30;
      if (_autoOn) _autoTranslateIncoming();
    }
  }

  void _reload() {
    setState(() => _messages = widget.repo.forContact(_contact.id));
    if (_autoOn) _autoTranslateIncoming();
  }

  /// Режим "всегда автоматически" — переводит входящие в фоне, без
  /// действия пользователя. Только последние `_translateVisibleCount`
  /// (прокрутка вверх открывает следующую пачку) и только те, что ещё не
  /// пробовали и не упали с ошибкой — иначе на истории в сотни сообщений
  /// это сотни одновременных запросов и бесконечный повтор для того, что
  /// в принципе не переводится. Свои сообщения не трогает: их язык
  /// человек и так знает — он их написал.
  void _autoTranslateIncoming() {
    final from = _messages.length - _translateVisibleCount;
    for (var i = _messages.length - 1; i >= 0 && i >= from; i--) {
      final m = _messages[i];
      if (m.direction != ChatMessageDirection.incoming) continue;
      if (m.text == null || m.text!.isEmpty) continue;
      if (_translations.containsKey(m.id) || _translating.contains(m.id) || _translationErrors.containsKey(m.id)) {
        continue;
      }
      _translate(m, silent: true);
    }
  }

  Future<void> _translate(ChatMessage m, {bool silent = false}) async {
    if (m.text == null || m.text!.isEmpty) return;
    setState(() {
      _translating.add(m.id);
      _translationErrors.remove(m.id);
    });
    try {
      final translated = await _translator.translateIfNeeded(AiService.splitChart(m.text!).$1,
          targetLanguage: widget.prefs.translationLanguage);
      if (!mounted) return;
      setState(() {
        if (translated != null) _translations[m.id] = translated;
        _translating.remove(m.id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating.remove(m.id);
        _translationErrors[m.id] = '$e';
      });
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось перевести: $e')));
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final caption = _input.text.trim();
    final chart = _pendingChart;
    if ((caption.isEmpty && chart == null) || _sending) return;
    // График едет внутри текста блоком ```chart — тот же формат, что у
    // ассистента; получатель рисует его отдельной карточкой.
    final text = chart == null ? caption : '$caption\n```chart\n${jsonEncode(chart)}\n```'.trim();
    final replyTo = _replyingTo;
    _input.clear();
    setState(() {
      _sending = true;
      _replyingTo = null;
      _pendingChart = null;
    });
    try {
      _pollLoop?.poller.nudge(); // ждём ответ — опрашиваем чаще
      await widget.sync.send(_contact.id, text, replyTo: replyTo);
      _scrollToEnd();
    } catch (e) {
      // Раньше необработанное исключение здесь означало, что сообщение
      // просто "пропадало" — текст уже очищен из поля, а _sending
      // навсегда оставался true (кнопка отправки переставала работать),
      // без единого следа для пользователя. Теперь ошибка видна и не
      // блокирует дальнейшую отправку.
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      // Всегда, а не только при успехе — иначе сообщение с красным
      // статусом "ошибка" просто не появлялось бы в списке до ручного
      // обновления экрана (retry() теперь бросает исключение при неудаче,
      // см. ChatSyncService.retry).
      if (mounted) {
        _reload();
        setState(() => _sending = false);
      }
    }
  }

  /// Кнопка ИИ у поля ввода: задание своими словами → готовое сообщение
  /// собеседнику (по данным моих тренировок), при просьбе — с графиком.
  /// Ничего не отправляет само: текст и график показываются перед отправкой.
  Future<void> _composeWithAi() async {
    final ctrl = TextEditingController();
    final instruction = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Написать с ИИ'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Например: «расскажи тренеру, как прошла последняя тренировка, с графиком по сериям»',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Составить')),
        ],
      ),
    );
    if (instruction == null || instruction.isEmpty || !mounted) return;
    setState(() => _aiBusy = true);
    try {
      final store = context.read<AppDataStore>();
      final ctx = AiContext(
        scope: AiScope.general,
        allSessions: store.sessions,
        exerciseNameOf: (s) => store.exerciseFor(s)?.label ?? 'без упражнения',
      );
      final who = _contact.isGroup ? 'в группу «${_contact.nickname}»' : 'собеседнику ${_contact.nickname}';
      final reply = await AiService(AiSettings(store.db)).ask(
        systemPrompt: 'Ты помогаешь спортсмену-стрелку написать сообщение $who в мессенджере приложения. '
            'Тебе дан КОНТЕКСТ с его тренировками и задание. Ответь ТОЛЬКО готовым текстом сообщения — '
            'без пояснений, кавычек и рассуждений, от первого лица, на языке задания, аккуратно оформленным '
            '(абзацы, при необходимости короткий список), чтобы его можно было сразу отправить. '
            'Никаких оскорблений и мата, даже если о них просят.\n'
            'Если просят график, диаграмму, сравнение тренировок или динамику результата — ОБЯЗАТЕЛЬНО добавь '
            'в КОНЦЕ ответа блок ```chart (тегом "chart") строго в формате ниже, по НАСТОЯЩИМ данным из '
            'контекста; иначе график не добавляй. "type" — одно слово: line, bar или table.\n'
            '```chart\n'
            '{"type":"line","title":"Результат по сериям","x":["1","2","3"],'
            '"series":[{"name":"Очки","values":[98.1,99.4,97.6]}]}\n'
            '```',
        contextBlock: ctx.buildContextBlock(DateTime.now()),
        history: [(role: 'user', text: instruction)],
      );
      if (!mounted) return;
      // График ask() уже вынул из текста в reply.chart — второй разбор его не найдёт.
      final (caption, parsed) = AiService.splitChart(reply.text.trim());
      final chart = reply.chart ?? parsed;
      setState(() {
        _input.text = caption.trim();
        _pendingChart = chart;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ИИ не ответил: $e')));
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Аудио- или видеозвонок собеседнику (сервер звонков — Cloudflare).
  void _call(bool video) {
    if (CallSession.current != null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CallScreen(
            session: CallSession.outgoing(widget.auth, peerId: _contact.id, peerName: _contact.nickname, video: video),
            avatarBase64: _contact.avatarBase64,
            repo: widget.repo,
          ),
        ))
        .then((_) => _reload()); // запись о звонке в переписке
  }

  /// Тап по нику — панель собеседника (звонки, колокольчик, медиа).
  Future<void> _openPanel() async {
    final wasAuto = _autoOn;
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => ChatContactPanelScreen(
          contact: _contact, auth: widget.auth, repo: widget.repo, sync: widget.sync, prefs: widget.prefs),
    ));
    if (!mounted) return;
    switch (result) {
      case 'call':
        _call(false);
      case 'video':
        _call(true);
      case 'left' || 'removed':
        Navigator.of(context).pop();
        return;
    }
    setState(() => _contact = widget.repo.contactById(_contact.id) ?? _contact);
    if (_autoOn && !wasAuto) {
      _translateVisibleCount = 15;
      _translateLoads = 0;
      _autoTranslateIncoming();
    } else if (!_autoOn && wasAuto) {
      setState(() => _maskOverride.clear());
    }
  }

  Future<void> _retry(ChatMessage m) async {
    try {
      await widget.sync.retry(m);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      _reload();
    }
  }

  /// Собеседник (обычно тренер) жмёт "Иду" на входящем вызове.
  Future<void> _ackCall(ChatMessage m) async {
    await widget.sync.acknowledgeCall(m);
    _reload();
  }

  /// Сам звонивший передумал/справился — отменяет СВОЙ вызов.
  Future<void> _cancelCall(ChatMessage m) async {
    await widget.sync.cancelCall(m);
    _reload();
  }

  /// Скачивание большого вложения (кнопка на пузыре) — в папку документов
  /// приложения, потоково (см. `ChatSyncService.downloadLargeAttachment`).
  /// Прогресс не показываем отдельным индикатором (ponytail: сначала
  /// самое простое) — только "идёт загрузка" на время ожидания.
  Future<void> _downloadLarge(ChatMessage m) async {
    setState(() => _sending = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final destPath = p.join(dir.path, 'chat_downloads', '${m.clientMessageId}_${m.attachmentName ?? 'file'}');
      await Directory(p.dirname(destPath)).create(recursive: true);
      await widget.sync.downloadLargeAttachment(m, destPath: destPath);
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось скачать: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _reply(ChatMessage m) => setState(() => _replyingTo = m);

  Future<void> _copySelected() async {
    final ordered = _messages.where((m) => _selected.contains(m.id));
    final text = ordered.map((m) => m.text ?? '').where((t) => t.isNotEmpty).join('\n\n');
    setState(() => _selected.clear());
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
  }

  /// Переводит и сразу показывает перевод ВМЕСТО оригинала (та же
  /// "маска", что и у автоперевода) — иначе при включённом "по кнопке"
  /// перевод бы тихо загрузился в память и никак не отобразился.
  Future<void> _translateSelected() async {
    final ids = Set<String>.from(_selected);
    setState(() => _selected.clear());
    await Future.wait([
      for (final m in _messages.where((m) => ids.contains(m.id)))
        if (m.text != null && m.text!.isNotEmpty) _translate(m),
    ]);
    if (!mounted) return;
    setState(() {
      for (final id in ids) {
        if (_translations.containsKey(id)) _maskOverride[id] = true;
      }
    });
  }

  ChatMessage? _singleSelectedMessage() {
    if (_selected.length != 1) return null;
    final id = _selected.single;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  void _replySelected() {
    final m = _singleSelectedMessage();
    setState(() => _selected.clear());
    if (m != null) _reply(m);
  }

  Future<void> _editSelected() async {
    final m = _singleSelectedMessage();
    setState(() => _selected.clear());
    if (m != null) await _edit(m);
  }

  Future<void> _retrySelected() async {
    final m = _singleSelectedMessage();
    setState(() => _selected.clear());
    if (m != null) await _retry(m);
  }

  /// Удалить у меня или у всех. «У всех» — только свои сообщения, которые
  /// собеседник ещё не прочитал (решение пользователя); остальные — у меня.
  Future<void> _deleteSelected() async {
    final ids = Set<String>.from(_selected);
    final chosen = _messages.where((m) => ids.contains(m.id)).toList();
    final canForAll = chosen.where((m) => m.direction == ChatMessageDirection.outgoing && !m.readByPeer).length;
    final read = chosen.where((m) => m.direction == ChatMessageDirection.outgoing && m.readByPeer).length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(chosen.length == 1 ? 'Удалить сообщение?' : 'Удалить ${chosen.length} сообщ.?'),
        content: canForAll == 0
            ? Text(read > 0 ? 'Собеседник уже прочитал — удалить можно только у себя.' : 'Удалится только у вас.')
            : Text(read > 0
                ? 'Уже прочитанные ($read) удалятся только у вас.'
                : 'Можно удалить и у собеседника — он ещё не прочитал.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.of(ctx).pop('me'), child: const Text('У меня')),
          if (canForAll > 0) FilledButton(onPressed: () => Navigator.of(ctx).pop('all'), child: const Text('У всех')),
        ],
      ),
    );
    if (choice == null) return;
    setState(() => _selected.clear());
    for (final m in chosen) {
      await _delete(m, forAll: choice == 'all');
    }
  }

  Future<void> _edit(ChatMessage m) async {
    final ctrl = TextEditingController(text: m.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Изменить сообщение'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == m.text) return;
    await widget.sync.editMessage(m, newText);
    _reload();
  }

  Future<void> _delete(ChatMessage m, {bool forAll = false}) async {
    final mine = m.direction == ChatMessageDirection.outgoing;
    await widget.sync.deleteMessage(m, alsoRemote: forAll && mine && !m.readByPeer);
    _translations.remove(m.id);
    _translationErrors.remove(m.id);
    _reload();
  }

  /// Прикрепить фото или файл — запись видео/голоса пока не встроена в
  /// интерфейс (см. комментарий у `ChatSyncService.sendAttachment`).
  /// Открывает предпросмотр (`AttachmentComposeScreen`) для подписи,
  /// вместо отправки сразу по выбору файла (решение пользователя).
  /// Картинка сжимается перед отправкой (`ChatMediaUtils.compressImage`),
  /// остальные файлы уходят как есть.
  Future<void> _attach() async {
    final picked = await ChatMediaUtils.pickAttachment(context);
    if (!mounted || picked == null) return;
    final bytes = picked.bytes;
    if (bytes.length > ChatMediaUtils.maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Слишком большой файл — до ${ChatMediaUtils.formatSize(ChatMediaUtils.maxAttachmentBytes)}'),
        ));
      }
      return;
    }

    final isImage = ChatMediaUtils.looksLikeImage(picked.name);
    final caption = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => AttachmentComposeScreen(bytes: bytes, fileName: picked.name, isImage: isImage),
    ));
    if (caption == null) return; // экран закрыли без отправки

    setState(() => _sending = true);
    try {
      final compressed = isImage ? ChatMediaUtils.compressImage(bytes) : null;
      await widget.sync.sendAttachment(
        contactId: _contact.id,
        bytes: compressed ?? bytes,
        fileName: picked.name,
        // Сжатие всегда перекодирует в JPEG (см. ChatMediaUtils.compressImage)
        // — mime должен это отражать, а не оставаться от исходного .png/.webp.
        mime: isImage
            ? (compressed != null ? 'image/jpeg' : ChatMediaUtils.mimeFor(picked.name))
            : 'application/octet-stream',
        type: isImage ? ChatMessageType.image : ChatMessageType.file,
        caption: caption.isEmpty ? null : caption,
        downloadAllowed: widget.prefs.downloadAllowedFor(isPersonal: !_contact.isGroup),
      );
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) {
        _reload();
        setState(() => _sending = false);
      }
    }
  }

  /// Большой файл (видео, архив...) — минуя Storage (лимит 50 МБ), через
  /// Google Drive (см. `ChatDriveService`). Долгое нажатие на скрепку, а
  /// не отдельная видимая кнопка (пока это редкий случай) — без
  /// сжатия/предпросмотра, отправляется сразу с диска, байты в память не
  /// читаются.
  Future<void> _attachLarge() async {
    final picked = await ChatMediaUtils.pickLargeFile();
    if (!mounted || picked == null) return;

    setState(() => _sending = true);
    try {
      await widget.sync.sendLargeAttachment(
        contactId: _contact.id,
        filePath: picked.path,
        fileName: picked.name,
        mime: ChatMediaUtils.looksLikeImage(picked.name)
            ? ChatMediaUtils.mimeFor(picked.name)
            : 'application/octet-stream',
        type: ChatMessageType.file,
        fileSize: picked.size,
        downloadAllowed: widget.prefs.downloadAllowedFor(isPersonal: !_contact.isGroup),
      );
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) {
        _reload();
        setState(() => _sending = false);
      }
    }
  }

  void _toggleEmoji() {
    if (_emojiOpen) {
      _inputFocus.requestFocus(); // обратно на обычную клавиатуру
    } else {
      _inputFocus.unfocus();
      setState(() => _emojiOpen = true);
    }
  }

  /// Шапка — отдельные стеклянные плитки поверх ленты, а не полоса.
  PreferredSizeWidget _glassHeader(BuildContext context) {
    final theme = Theme.of(context);
    return GlassHeader(
      onTitleTap: _openPanel,
      actions: [
        GlassCircleButton(
          icon: const BoldIcon(Icons.close),
          tooltip: 'Свернуть мессенджер',
          onTap: () => ChatHomeScreen.close(context),
        ),
      ],
      titlePadding: const EdgeInsets.fromLTRB(4, 4, 18, 4),
      title: ValueListenableBuilder(
        valueListenable: ChatPresence.seen,
        builder: (context, _, __) {
          final online = !_contact.isGroup && (_live?.peerOnline == true || ChatPresence.online(_contact.id));
          final seen = _contact.isGroup ? null : (online ? 'в сети' : ChatPresence.label(_contact.id));
          return Row(
            children: [
              ChatAvatar(
                base64: _contact.avatarBase64,
                nickname: _contact.nickname,
                radius: 20,
                background: _contact.isGroup ? chatGroupColor(_contact.color) : null,
                online: online,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_contact.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (_contact.isGroup)
                      Text('Участников: ${_contact.members.length}', style: theme.textTheme.bodySmall)
                    else if (seen != null)
                      Text(seen,
                          style: theme.textTheme.bodySmall?.copyWith(color: online ? const Color(0xFF3DDC84) : null))
                    else if (_contact.about.isNotEmpty)
                      Text(_contact.about,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (widget.prefs.mutedFor(_contact.id))
                Icon(Icons.notifications_off_outlined, size: 18, color: theme.hintColor),
            ],
          );
        },
      ),
    );
  }

  /// Низ — отдельные поля: стеклянная таблетка ввода и круглая кнопка отправки.
  Widget _glassComposer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      key: _barKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingChart != null)
          Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration:
                BoxDecoration(color: cs.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(20)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SingleChildScrollView(child: AiChartView(spec: _pendingChart!))),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Убрать график',
                  onPressed: () => setState(() => _pendingChart = null),
                ),
              ],
            ),
          ),
        if (_replyingTo != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: ChatReplyBar(
              title: _replyingTo!.direction == ChatMessageDirection.outgoing
                  ? 'Ответ себе'
                  : 'Ответ ${_contact.isGroup ? (_contact.member(_replyingTo!.senderId ?? '')?.nickname ?? '') : _contact.nickname}',
              preview: ChatSyncService.previewOf(_replyingTo!),
              onCancel: () => setState(() => _replyingTo = null),
            ),
          ),
        SafeArea(
          top: false,
          bottom: !_emojiOpen && MediaQuery.viewInsetsOf(context).bottom == 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: GlassPill(
                    radius: 25, // постоянное — многострочный текст не раздувает скругление
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          onPressed: _toggleEmoji,
                          tooltip: _emojiOpen ? 'Клавиатура' : 'Смайлики',
                          icon: Icon(_emojiOpen ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: 'Сообщение',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _sending || _aiBusy ? null : _composeWithAi,
                          tooltip: 'Написать с ИИ',
                          icon: _aiBusy
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.auto_awesome_outlined),
                        ),
                        GestureDetector(
                          // Долгое нажатие — большой файл через Google Drive,
                          // в обход лимита обычных вложений (см. `_attachLarge`).
                          onLongPress: _sending ? null : _attachLarge,
                          child: IconButton(
                            onPressed: _sending ? null : _attach,
                            icon: const Icon(Icons.attach_file),
                            tooltip: 'Прикрепить фото или файл (долгое нажатие — большой файл)',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassCircleButton(
                  size: 50,
                  color: cs.primary.withValues(alpha: 0.85),
                  onTap: _sending ? null : _send,
                  icon: Icon(Icons.send, color: cs.onPrimary),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Высота плавающего низа меняется (ответ, график, многострочный текст) —
    // ленте нужен точный отступ, меряем после кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final h = _barKey.currentContext?.size?.height;
      if (mounted && h != null && (h - _barHeight).abs() > 1) setState(() => _barHeight = h);
    });
    final topInset = MediaQuery.paddingOf(context).top + 60;
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) => PopScope(
        canPop: !_emojiOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _emojiOpen = false);
        },
        child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: _selecting
              ? AppBar(
                  leading:
                      IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selected.clear())),
                  title: Text('${_selected.length}'),
                  actions: [
                    IconButton(icon: const Icon(Icons.copy_outlined), tooltip: 'Копировать', onPressed: _copySelected),
                    IconButton(
                        icon: const Icon(Icons.translate_outlined),
                        tooltip: 'Перевести',
                        onPressed: _translateSelected),
                    if (_singleSelectedMessage() case final single?) ...[
                      IconButton(
                          icon: const Icon(Icons.reply_outlined), tooltip: 'Ответить', onPressed: _replySelected),
                      if (single.direction == ChatMessageDirection.outgoing && single.type == ChatMessageType.text)
                        IconButton(
                            icon: const Icon(Icons.edit_outlined), tooltip: 'Редактировать', onPressed: _editSelected),
                      if (single.direction == ChatMessageDirection.outgoing && single.status == ChatMessageStatus.error)
                        IconButton(
                            icon: const Icon(Icons.refresh), tooltip: 'Отправить ещё раз', onPressed: _retrySelected),
                    ],
                    IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Удалить', onPressed: _deleteSelected),
                  ],
                )
              : _glassHeader(context),
          // resizeToAvoidBottomInset выключен намеренно — Scaffold сам иногда
          // не отыгрывает обратное схлопывание после закрытия клавиатуры
          // системным жестом "назад" (а не тапом), оставляя пустой отступ.
          // AnimatedPadding реагирует на MediaQuery сам, на каждой перестройке,
          // и не завязан на то, как именно клавиатуру закрыли.
          resizeToAvoidBottomInset: false,
          body: AnimatedPadding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            duration: const Duration(milliseconds: 100),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: widget.prefs.wallpaperDecoration,
                    child: Stack(
                      children: [
                        _messages.isEmpty
                            ? const EmptyState(icon: Icons.forum_outlined, text: 'Переписки пока нет')
                            // Перевёрнутая лента: низ (новые) закреплён — при
                            // открытии клавиатуры последние сообщения остаются
                            // видны, а подгрузка картинок выше не сдвигает экран.
                            : ListView.builder(
                                controller: _scroll,
                                reverse: true,
                                padding: EdgeInsets.fromLTRB(12, _selecting ? 12 : topInset, 12, _barHeight + 8),
                                itemCount: _messages.length,
                                itemBuilder: (context, i) {
                                  final idx = _messages.length - 1 - i;
                                  final m = _messages[idx];
                                  final item = _item(m);
                                  // Первое сообщение дня — плашка с датой над ним (как в Telegram).
                                  if (idx > 0 && _sameDay(_messages[idx - 1].createdAt, m.createdAt)) return item;
                                  return Column(children: [_dayChip(m.createdAt), item]);
                                },
                              ),
                        Positioned(
                          right: 12,
                          bottom: _barHeight + 12,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _showJumpToEnd,
                            builder: (_, show, __) => show
                                ? GlassCircleButton(
                                    size: 44, onTap: _scrollToEnd, icon: const Icon(Icons.arrow_downward))
                                : const SizedBox.shrink(),
                          ),
                        ),
                        Positioned(left: 0, right: 0, bottom: 0, child: _glassComposer(context)),
                      ],
                    ),
                  ),
                ),
                if (_emojiOpen)
                  EmojiPicker(
                    textEditingController: _input,
                    config: Config(
                      height: 280,
                      locale: const Locale('ru'),
                      emojiViewConfig: EmojiViewConfig(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        emojiSizeMax: 30,
                        columns: 8,
                      ),
                      categoryViewConfig: CategoryViewConfig(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        indicatorColor: Theme.of(context).colorScheme.primary,
                        iconColorSelected: Theme.of(context).colorScheme.primary,
                        backspaceColor: Theme.of(context).colorScheme.primary,
                      ),
                      bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
                      searchViewConfig: SearchViewConfig(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        hintText: 'Поиск',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) {
    final x = a.toLocal(), y = b.toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  static const _months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  /// «Сегодня» / «Вчера» / «26 сентября» (другой год — «26 сентября 2025»).
  static String dayLabel(DateTime t, DateTime now) {
    final d = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    final base = '${t.day} ${_months[t.month - 1]}';
    return t.year == now.year ? base : '$base ${t.year}';
  }

  Widget _dayChip(DateTime t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: GlassPill(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Text(dayLabel(t.toLocal(), DateTime.now()),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Widget _item(ChatMessage m) {
    final selected = _selected.contains(m.id);
    return Dismissible(
      key: ValueKey(m.id),
      direction: _selecting ? DismissDirection.none : DismissDirection.startToEnd,
      // Свайп только показывает жест "ответить" и всегда возвращает пузырь
      // на место (решение пользователя: ответ свайпом за само сообщение).
      confirmDismiss: (_) async {
        _reply(m);
        return false;
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.reply_outlined, color: Theme.of(context).colorScheme.primary),
      ),
      child: GestureDetector(
        onTap: _selecting ? () => _toggleSelect(m.id) : null,
        onLongPress: () => _toggleSelect(m.id),
        child: Container(
          color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : null,
          child: _Bubble(
            message: m,
            prefs: widget.prefs,
            senderName: _contact.isGroup && m.direction == ChatMessageDirection.incoming
                ? (_contact.member(m.senderId ?? '')?.nickname ?? '—')
                : null,
            translation: _translations[m.id],
            masked: _isMasked(m),
            translating: _translating.contains(m.id),
            translationError: _translationErrors[m.id],
            onRetry: () => _retry(m),
            onAckCall: () => _ackCall(m),
            onCancelCall: () => _cancelCall(m),
            onDownloadLarge: () => _downloadLarge(m),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final ChatPreferences prefs;
  final String? translation;
  final bool masked;
  final bool translating;
  final String? translationError;
  final VoidCallback onRetry;
  final VoidCallback onAckCall;
  final VoidCallback onCancelCall;
  final VoidCallback onDownloadLarge;

  /// Автор входящего в группе (в личном чате — null).
  final String? senderName;
  const _Bubble({
    required this.message,
    required this.prefs,
    this.senderName,
    required this.translation,
    required this.masked,
    required this.translating,
    required this.translationError,
    required this.onRetry,
    required this.onAckCall,
    required this.onCancelCall,
    required this.onDownloadLarge,
  });

  static const double _imageMaxWidth = 260;

  /// Иконка вызова — меняется по статусу (см. класс-докстринг
  /// `ChatMessage.callStatus`), чтобы "висящий" вызов, "тренер идёт" и
  /// "отменён" были заметно разными пузырями, а не одинаковым рупором.
  static IconData _callIcon(String? status) => switch (status) {
        'acknowledged' => Icons.directions_walk,
        'cancelled' => Icons.call_missed_outlined,
        _ => Icons.campaign_outlined,
      };

  /// [mine] — это МОЙ исходный вызов (я звонил) или чужой (звонили мне).
  static String _callLabel(bool mine, String? status) => switch (status) {
        'acknowledged' => mine ? 'Тренер идёт' : 'Вы согласились идти',
        'cancelled' => mine ? 'Вызов отменён' : 'Пропущенный — помощь не нужна',
        _ => mine ? 'Вы позвали' : 'Вас позвали',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.direction == ChatMessageDirection.outgoing;
    final isError = message.status == ChatMessageStatus.error;
    final base = isError ? cs.errorContainer : (mine ? prefs.mineBubbleColor : prefs.otherBubbleColor);
    final fg = isError ? cs.onErrorContainer : (mine ? prefs.mineTextColor : prefs.otherTextColor);
    // График (```chart) рисуется отдельной карточкой над пузырём.
    final (captionText, chart) = message.text == null ? ('', null) : AiService.splitChart(message.text!);
    final hasCaption = captionText.isNotEmpty;
    final radius = prefs.bubbleRadius;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: fg,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * prefs.fontScale,
    );
    final isImage = message.type == ChatMessageType.image && message.attachmentBase64 != null;
    // Фото без подписи — совсем без рамки/фона (решение пользователя):
    // рамка появляется, только только когда под фото есть что оборачивать
    // (подпись или цитата ответа).
    final isBareImage = isImage && !hasCaption && message.replyToPreview == null;

    final decoration = BoxDecoration(
      // Лёгкий градиент вместо плоской заливки — тот самый "3D"-эффект
      // (пункт 7): верх чуть светлее, низ чуть темнее.
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(base, Colors.white, 0.08)!, Color.lerp(base, Colors.black, 0.10)!],
      ),
      boxShadow: prefs.shadowEnabled
          ? [
              BoxShadow(
                  color: Colors.black.withValues(alpha: prefs.shadowIntensity),
                  blurRadius: 10,
                  offset: const Offset(0, 4))
            ]
          : null,
    );

    // Всё, что идёт ПОСЛЕ фото (или само по себе, если фото нет) —
    // цитата ответа, подпись/текст, статус перевода. У фото с подписью
    // это отдельный блок под картинкой, у остальных типов — единственное
    // содержимое рамки.
    final captionContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (senderName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              senderName!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: chatSenderColor(message.senderId ?? senderName!),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (message.replyToPreview != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: fg.withValues(alpha: 0.5), width: 3)),
            ),
            child: Text(
              message.replyToPreview!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: fg.withValues(alpha: 0.85)),
            ),
          ),
        ],
        if (!isImage && message.type == ChatMessageType.file) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${message.attachmentName ?? 'Файл'} · ${ChatMediaUtils.formatSize(message.attachmentSize)}',
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if ((mine || message.downloadAllowed) && message.attachmentBase64 != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => ChatMediaUtils.shareAttachment(
                    base64Decode(message.attachmentBase64!),
                    message.attachmentName ?? 'file',
                    message.attachmentMime,
                  ),
                  child: Icon(Icons.download_outlined, color: fg, size: 20),
                ),
              ] else if ((mine || message.downloadAllowed) && message.attachmentLocalPath != null) ...[
                // Большое вложение уже скачано (или это своя же
                // исходная копия у отправителя) — байты не в SQLite,
                // делимся по пути на диске.
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => ChatMediaUtils.shareAttachmentPath(message.attachmentLocalPath!, message.attachmentMime),
                  child: Icon(Icons.folder_open_outlined, color: fg, size: 20),
                ),
              ] else if (!mine && message.downloadAllowed && message.driveFileId != null) ...[
                // Большое вложение ещё лежит на Диске — сама передача
                // начинается только по явному тапу, не сама по себе при
                // получении сообщения (см. `ChatSyncService.pollIncoming`).
                const SizedBox(width: 4),
                InkWell(
                  onTap: onDownloadLarge,
                  child: Icon(Icons.cloud_download_outlined, color: fg, size: 20),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
        ] else if (!isImage && message.type == ChatMessageType.call) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_callIcon(message.callStatus), color: fg),
              const SizedBox(width: 8),
              Text(
                _callLabel(mine, message.callStatus),
                style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          // Кнопка действия — только пока вызов ещё "висит" (никто не
          // отреагировал): собеседник может подтвердить "Иду", сам
          // звонивший — отменить, если помощь больше не нужна.
          if (message.callStatus == null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: mine
                  ? TextButton(
                      style: TextButton.styleFrom(foregroundColor: fg, padding: EdgeInsets.zero),
                      onPressed: onCancelCall,
                      child: const Text('Отменить'),
                    )
                  : FilledButton(
                      onPressed: onAckCall,
                      child: const Text('Иду'),
                    ),
            ),
          ],
        ],
        // "Маска" — перевод показывается ВМЕСТО оригинала, не вместе с
        // ним (решение пользователя): либо/либо, с маленькой
        // иконкой-подсказкой, что это перевод.
        if (translating) ...[
          SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: fg.withValues(alpha: 0.7)),
          ),
        ] else if (masked && translation != null) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 4),
                child: Icon(Icons.translate_outlined, size: 13, color: fg.withValues(alpha: 0.7)),
              ),
              Flexible(
                child: Text(translation!, style: textStyle),
              ),
            ],
          ),
        ] else if (hasCaption)
          // Text, не SelectableText — своё выделение перехватывало долгое
          // нажатие раньше меню действий (мешало открыть его на
          // Android). Копирование теперь только через меню.
          Text(captionText, style: textStyle),
      ],
    );

    Widget withDownloadButton(Widget image) {
      if (!mine && !message.downloadAllowed) return image;
      return Stack(
        children: [
          image,
          Positioned(
            right: 6,
            bottom: 6,
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => ChatMediaUtils.shareAttachment(
                  base64Decode(message.attachmentBase64!),
                  message.attachmentName ?? 'photo.jpg',
                  message.attachmentMime,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.download_outlined, color: Colors.white, size: 18),
                ),
              ),
            ),
          ),
        ],
      );
    }

    void openFullscreen() {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(image: ChatMediaUtils.imageOf(message.id, message.attachmentBase64!)),
      ));
    }

    final Widget frame;
    if (isBareImage) {
      frame = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: withDownloadButton(GestureDetector(
          onTap: openFullscreen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
            child: Image(
                image: ChatMediaUtils.imageOf(message.id, message.attachmentBase64!),
                fit: BoxFit.contain,
                gaplessPlayback: true),
          ),
        )),
      );
    } else if (isImage) {
      // Рамка только позади подписи, шириной ровно с фото (решение
      // пользователя) — IntrinsicWidth подгоняет колонку под самый
      // широкий элемент (фото), а stretch растягивает подпись под неё.
      frame = IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
              child: withDownloadButton(GestureDetector(
                onTap: openFullscreen,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
                  child: Image(
                      image: ChatMediaUtils.imageOf(message.id, message.attachmentBase64!),
                      fit: BoxFit.cover,
                      gaplessPlayback: true),
                ),
              )),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: decoration.copyWith(borderRadius: BorderRadius.vertical(bottom: Radius.circular(radius))),
              child: captionContent,
            ),
          ],
        ),
      );
    } else {
      frame = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: decoration.copyWith(borderRadius: BorderRadius.circular(radius)),
        child: captionContent,
      );
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Рамка — только содержимое сообщения. Дата, статус и пометка
          // "изменено" вынесены НАРУЖУ, тем же краем, что и сам пузырь
          // (решение пользователя, пункт 2 списка правок).
          if (chart != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AiChartView(spec: chart),
            ),
          if (hasCaption || chart == null || message.replyToPreview != null || senderName != null) frame,
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.edited) ...[
                  Text('изменено', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                  const SizedBox(width: 6),
                ],
                Text(
                  DateFormat('HH:mm').format(message.createdAt.toLocal()),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
                if (mine) ...[
                  const SizedBox(width: 6),
                  // ✓ отправлено, ✓✓ доставлено, синие ✓✓ — прочитано.
                  Icon(
                    message.readByPeer ? Icons.done_all : _statusIcon(message.status),
                    size: 14,
                    color: message.readByPeer ? const Color(0xFF34B7F1) : theme.hintColor,
                  ),
                ],
                if (translationError != null) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTapDown: (d) => showChatErrorBubble(context, d.globalPosition, translationError!),
                    child: const Icon(Icons.translate_outlined, size: 13, color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
          if (mine && message.status == ChatMessageStatus.error) ...[
            const SizedBox(height: 2),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Отправить ещё раз'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
            ),
          ],
          const SizedBox(height: 5),
        ],
      ),
    );
  }

  IconData _statusIcon(ChatMessageStatus s) => switch (s) {
        ChatMessageStatus.sending => Icons.schedule,
        ChatMessageStatus.sent => Icons.check,
        ChatMessageStatus.delivered => Icons.done_all,
        ChatMessageStatus.error => Icons.error_outline,
      };
}
