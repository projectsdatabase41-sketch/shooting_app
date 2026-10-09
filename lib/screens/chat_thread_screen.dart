import '../logic/friendly_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
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
import '../widgets/file_chip.dart';
import '../widgets/reaction_bar.dart';
import 'attachment_viewer.dart';
import '../logic/save_to_app_folder.dart';
import '../services/call_service.dart';
import '../services/message_sound.dart';
import '../services/web_push_token.dart';
import '../services/chat_sync_service.dart';
import '../services/push_service.dart' show pendingCallAckContactId;
import '../widgets/link_signal.dart';
import '../services/chat_translation_service.dart';
import '../services/group_live_session.dart';
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
import 'dart:typed_data' show Uint8List;
import 'photo_viewer_screen.dart';
import '../i18n/i18n.dart';
import '../widgets/messenger_bubble.dart';

/// Переписка с одним контактом. Открытие ветки сразу отмечает входящие
/// прочитанными локально (сервер их к этому моменту уже не хранит — см.
/// `ChatSyncService.pollIncoming`).
class ChatThreadScreen extends StatefulWidget {
  final ChatContact contact;
  final ChatAuthService auth;
  final ChatMessagesRepository repo;
  final ChatSyncService sync;
  final ChatPreferences prefs;

  /// Переписка встроена во вкладку «Тренер» на тренировке: без стрелки
  /// «назад» и кнопки «Свернуть», вместо неё в шапке — колокольчик
  /// «Вызвать тренера» (см. `AthleteCoachChat`).
  final bool embedded;

  const ChatThreadScreen({
    super.key,
    this.embedded = false,
    required this.contact,
    required this.auth,
    required this.repo,
    required this.sync,
    required this.prefs,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen>
    with WidgetsBindingObserver {
  late ChatContact _contact = widget.contact;
  final _input = TextEditingController();
  // Лента на scrollable_positioned_list: умеет прыгать к сообщению по
  // номеру (поиск по чату) при сообщениях разной высоты.
  final _itemCtl = ItemScrollController();
  final _itemPos = ItemPositionsListener.create();
  PollLoop? _pollLoop;
  LiveChatSession? _live;
  GroupLiveSession? _groupLive;
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
  /// client_message_id -> (user_id -> смайлик).
  Map<String, Map<String, String>> _reactions = {};

  Future<void> _react(ChatMessage m, String emoji) async {
    final mine = _reactions[m.clientMessageId]?[widget.auth.userId];
    final next = mine == emoji ? null : emoji; // тот же смайлик — снять
    setState(() {
      final map = _reactions[m.clientMessageId] ??= {};
      if (next == null) {
        map.remove(widget.auth.userId);
      } else {
        map[widget.auth.userId] = next;
      }
    });
    await widget.sync.react(m, next);
  }

  Widget _reactionChips(ChatMessage m) {
    final map = _reactions[m.clientMessageId];
    if (map == null || map.isEmpty) return const SizedBox.shrink();
    final counts = <String, int>{};
    for (final e in map.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mine = map[widget.auth.userId];
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final e in counts.entries)
            GestureDetector(
              onTap: () => _react(m, e.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: e.key == mine
                      ? cs.primary.withValues(alpha: 0.25)
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: e.key == mine ? cs.primary : Colors.transparent),
                ),
                child: Text(e.value > 1 ? '${e.key} ${e.value}' : e.key,
                    style: const TextStyle(fontSize: 14)),
              ),
            ),
        ],
      ),
    );
  }

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
    return _autoOn &&
        m.direction == ChatMessageDirection.incoming &&
        _translations.containsKey(m.id);
  }

  @override
  void initState() {
    super.initState();
    _lastTranslationLanguage = widget.prefs.translationLanguage;
    WidgetsBinding.instance.addObserver(this);
    widget.prefs.addListener(_onPrefsChanged);
    webSetActiveChat(_contact.id);
    _reactions = widget.repo.reactionsForContact(_contact.id);
    _saved = widget.repo.savedFor(_contact.id);
    widget.repo.markThreadSeen(_contact.id);
    widget.sync.reportRead(_contact.id);
    // Открыли переписку — сразу спросить «в сети», не ждать общего тика
    // с домашнего экрана; если поднимется живой канал ниже, он даст
    // мгновенный статус и без этого опроса.
    if (!_contact.isGroup) ChatPresence.tick(widget.auth, force: true);
    _reload();
    _itemPos.itemPositions.addListener(_onScroll);
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus && _emojiOpen)
        setState(() => _emojiOpen = false);
    });
    // Живой канал (WebSocket/WebRTC) — включается удалённо, по умолчанию выключен.
    _startLive();
    // Адаптивный опрос: пока собеседник пишет — каждые 2-3 секунды, в тишине
    // растёт до 15 (см. AdaptivePoller). Отправка своего сообщения возвращает
    // частый режим — ответ обычно приходит скоро.
    _pollLoop = PollLoop(
      poller: AdaptivePoller(
          min: const Duration(seconds: 2, milliseconds: 500),
          max: const Duration(seconds: 15),
          scale: () =>
              RemoteConfig.pollScale *
              // Живой канал не гарантирует доставку: сообщение, не получившее
              // ack за 3 с, уходит только в базу, и получатель найдёт его
              // лишь опросом. Раньше при онлайне опрос замедлялся вчетверо
              // (до минуты) — отсюда «сообщение приходит, когда сам напишу».
              (_live?.peerOnline == true || (_groupLive?.onlineCount ?? 0) > 1
                  ? 2
                  : 1)),
      tick: () async {
        final added = await widget.sync.pollIncoming();
        if (added > 0 && mounted) {
          _markRead();
          _reload();
          _scrollToEnd();
        }
        return added > 0;
      },
    )..start();
    _pollLoop!.poke(); // открыли диалог — сразу забираем то, что лежит в базе
  }

  /// Приложение на переднем плане. Свёрнутое НЕ должно «читать» сообщения:
  /// иначе собеседник видит «прочитано», а push пользователю не приходит
  /// (жалоба: «читал, не читая»).
  bool _foreground = true;

  void _markRead() {
    if (!_foreground) return;
    widget.repo.markThreadSeen(_contact.id);
    if (!_contact.isGroup) widget.sync.reportRead(_contact.id);
  }

  /// Личный чат — через общий реестр (соединение переживает выход из чата в
  /// список мессенджера, см. `LiveSessions`); группа — своё на экран.
  void _startLive() {
    if (!_contact.isGroup) {
      _live = LiveSessions.acquire(
        _contact.id,
        () => LiveChatSession(
          auth: widget.auth,
          repo: widget.repo,
          contactId: _contact.id,
          linkFactory: () =>
              WebRtcPeerLink(iceServers: CallService(widget.auth).iceServers),
        ),
      )
        ..onIncoming = () {
          if (!mounted) return;
          MessageSound.play();
          _markRead();
          _reload();
          _scrollToEnd();
        }
        ..onPeerRead = () {
          if (mounted) _reload();
        };
      widget.sync.live = _live;
    } else {
      _groupLive = GroupLiveSession(
        auth: widget.auth,
        repo: widget.repo,
        groupId: _contact.id,
        onIncoming: () {
          if (!mounted) return;
          MessageSound.play();
          _markRead();
          _reload();
          _scrollToEnd();
        },
        onPresenceChanged: () {
          if (mounted) setState(() {});
        },
      );
      widget.sync.groupLive = _groupLive;
      _groupLive!.open();
    }
  }

  void _stopLive() {
    if (widget.sync.live == _live) widget.sync.live = null;
    if (_live != null) LiveSessions.release(_contact.id);
    _live = null;
    if (widget.sync.groupLive == _groupLive) widget.sync.groupLive = null;
    _groupLive?.close();
    _groupLive = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_foreground) return;
      _foreground = true;
      _startLive();
      _pollLoop?.start();
      _pollLoop?.poke();
      _markRead();
      if (mounted) _reload();
    } else if (_foreground) {
      // Свёрнули: рвём живой канал (сообщения пойдут через базу и дадут push)
      // и не опрашиваем сервер, пока не вернулись.
      _foreground = false;
      _pollLoop?.stop();
      _stopLive();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    webSetActiveChat(null);
    widget.prefs.removeListener(_onPrefsChanged);
    _pollLoop?.stop();
    _stopLive();
    _flushTranslations?.cancel();
    _input.dispose();
    _itemPos.itemPositions.removeListener(_onScroll);
    _searchCtl.dispose();
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
    final pos = _itemPos.itemPositions.value;
    if (pos.isEmpty) return;
    var lo = pos.first.index, hi = pos.first.index;
    for (final p in pos) {
      if (p.index < lo) lo = p.index;
      if (p.index > hi) hi = p.index;
    }
    // Лента перевёрнута (reverse): индекс 0 — самое новое сообщение внизу.
    _showJumpToEnd.value = lo > 2;
    if (_translateVisibleCount >= _messages.length) return;
    if (hi >= _messages.length - 4) {
      // Последние 15, листаем выше — ещё 20, дальше по 30 (решение пользователя).
      _translateVisibleCount += _translateLoads++ == 0 ? 20 : 30;
      if (_autoOn) _autoTranslateIncoming();
    }
  }

  void _reload() {
    setState(() {
      _messages = widget.repo.forContact(_contact.id);
      _reactions = widget.repo.reactionsForContact(_contact.id);
      _saved = widget.repo.savedFor(_contact.id);
    });
    if (_autoOn) _autoTranslateIncoming();
    _autoAckCall();
  }

  /// Тренер принял вызов кнопкой «Иду» прямо на уведомлении — подтверждаем
  /// последний неотвеченный входящий вызов этого контакта сами. Флаг гасится
  /// только когда вызов найден: сообщение может подтянуться опросом позже.
  void _autoAckCall() {
    if (pendingCallAckContactId != _contact.id) return;
    for (final m in _messages.reversed) {
      if (m.type == ChatMessageType.call &&
          m.direction == ChatMessageDirection.incoming &&
          m.callStatus == null) {
        pendingCallAckContactId = null;
        widget.sync.acknowledgeCall(m).then((_) {
          if (mounted) {
            setState(() => _messages = widget.repo.forContact(_contact.id));
          }
        });
        return;
      }
    }
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
      if (_translations.containsKey(m.id) ||
          _translating.contains(m.id) ||
          _translationErrors.containsKey(m.id)) {
        continue;
      }
      _translate(m, silent: true);
    }
  }

  // Автоперевод приходит пачкой: каждое сообщение раньше перерисовывало ленту
  // дважды (начало и конец) — отсюда «дёргание». Теперь результаты копятся и
  // применяются одним setState раз в ~150 мс, а пока перевод идёт, оригинал
  // остаётся на месте (без спиннера вместо текста — высота не прыгает).
  final Map<String, String> _pendingTranslations = {};
  Timer? _flushTranslations;

  void _queueTranslation(String id, String text) {
    _pendingTranslations[id] = text;
    _flushTranslations ??= Timer(const Duration(milliseconds: 150), () {
      _flushTranslations = null;
      if (!mounted) return;
      setState(() {
        _translations.addAll(_pendingTranslations);
        _translating.removeAll(_pendingTranslations.keys);
        _pendingTranslations.clear();
      });
    });
  }

  Future<void> _translate(ChatMessage m, {bool silent = false}) async {
    if (m.text == null || m.text!.isEmpty) return;
    _translationErrors.remove(m.id);
    if (silent) {
      _translating.add(m.id); // без перерисовки: для ленты ничего не меняется
    } else {
      setState(() => _translating.add(m.id));
    }
    try {
      final translated = await _translator.translateIfNeeded(
          AiService.splitChart(m.text!).$1,
          targetLanguage: widget.prefs.translationLanguage);
      if (!mounted) return;
      if (translated != null) {
        _queueTranslation(m.id, translated);
      } else {
        setState(() => _translating.remove(m.id));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating.remove(m.id);
        _translationErrors[m.id] = friendlyError(e);
      });
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                tr('Не удалось перевести: {e}', {'e': friendlyError(e)}))));
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_itemCtl.isAttached) {
        _itemCtl.scrollTo(
            index: 0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  // ---- Поиск по переписке ----
  bool _searching = false;
  final _searchCtl = TextEditingController();
  List<int> _hits = []; // индексы в _messages, от новых к старым
  int _hitPos = 0;

  static String _norm(String t) => t.toLowerCase().replaceAll('ё', 'е');

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() => setState(() {
        _searching = false;
        _searchQuery = '';
        _searchCtl.clear();
        _hits = [];
        _hitPos = 0;
      });

  /// Ищет слово в тексте сообщений, названиях файлов и переводах.
  void _runSearch(String q) {
    final needle = _norm(q.trim());
    final hits = <int>[];
    if (needle.isNotEmpty) {
      for (var i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        final hay = _norm([
          if (m.text != null) AiService.splitChart(m.text!).$1,
          if (m.attachmentName != null) m.attachmentName!,
          if (_translations[m.id] != null) _translations[m.id]!,
        ].join(' '));
        if (hay.contains(needle)) hits.add(i);
      }
    }
    setState(() {
      _searchQuery = q.trim();
      _hits = hits;
      _hitPos = 0;
    });
    if (hits.isNotEmpty) _jumpToHit();
  }

  void _jumpToHit() {
    if (_hits.isEmpty || !_itemCtl.isAttached) return;
    final idx = _hits[_hitPos];
    _itemCtl.scrollTo(
        index: _messages.length - 1 - idx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  /// Листание вариантов: [older] — к более старому совпадению.
  void _stepHit({required bool older}) {
    if (_hits.isEmpty) return;
    setState(() => _hitPos = (_hitPos + (older ? 1 : -1)) % _hits.length);
    _jumpToHit();
  }

  PreferredSizeWidget _searchHeader(BuildContext context) {
    final theme = Theme.of(context);
    return GlassHeader(
      leading: GlassCircleButton(
        icon: const BoldIcon(Icons.arrow_back),
        tooltip: tr('Закрыть поиск'),
        onTap: _closeSearch,
      ),
      titlePadding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      actions: [
        GlassCircleButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          tooltip: tr('Предыдущее (старее)'),
          onTap: _hits.isEmpty ? null : () => _stepHit(older: true),
        ),
        const SizedBox(width: 6),
        GlassCircleButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: tr('Следующее (новее)'),
          onTap: _hits.isEmpty ? null : () => _stepHit(older: false),
        ),
      ],
      title: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _runSearch,
              onSubmitted: (_) => _stepHit(older: true),
              decoration: InputDecoration(
                hintText: tr('Поиск по переписке'),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            Text(
              _hits.isEmpty ? tr('нет') : '${_hitPos + 1}/${_hits.length}',
              style: theme.textTheme.labelMedium,
            ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final caption = _input.text.trim();
    final chart = _pendingChart;
    if ((caption.isEmpty && chart == null) || _sending) return;
    // График едет внутри текста блоком ```chart — тот же формат, что у
    // ассистента; получатель рисует его отдельной карточкой.
    final text = chart == null
        ? caption
        : '$caption\n```chart\n${jsonEncode(chart)}\n```'.trim();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
      }
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
        title: Text(tr('Написать с ИИ')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: tr(
                'Например: «расскажи тренеру, как прошла последняя тренировка, с графиком по сериям»'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(tr('Составить'))),
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
        exerciseNameOf: (s) =>
            store.exerciseFor(s)?.label ?? tr('без упражнения'),
      );
      final who = _contact.isGroup
          ? 'in the group "${_contact.nickname}"'
          : 'to ${_contact.nickname}';
      final reply = await AiService(AiSettings(store.db)).ask(
        systemPrompt:
            'You help a rifle/pistol shooting athlete write a message $who in the app messenger. '
            'You get a CONTEXT with their trainings and an instruction. Answer ONLY with the ready message text — '
            'no explanations, quotes or reasoning, in the first person, in the language of the instruction, neatly formatted '
            '(paragraphs, a short list if needed) so that it can be sent right away. '
            'No insults or profanity, even if asked for.\n'
            'If a chart, diagram, comparison of trainings or the dynamics of the result is requested — you MUST add '
            'a ```chart block (tagged "chart") at the END of the reply strictly in the format below, using REAL data from '
            'the context; otherwise do not add a chart. "type" is one word: line, bar, pie or table.\n'
            '```chart\n'
            '{"type":"line","title":"Result by series","x":["1","2","3"],'
            '"series":[{"name":"Score","values":[98.1,99.4,97.6]}]}\n'
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('ИИ не ответил: {e}', {'e': friendlyError(e)}))));
      }
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
            session: CallSession.outgoing(widget.auth,
                peerId: _contact.id, peerName: _contact.nickname, video: video),
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
          contact: _contact,
          auth: widget.auth,
          repo: widget.repo,
          sync: widget.sync,
          prefs: widget.prefs),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
      }
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

  /// Строка поиска по чату (пусто — поиск не идёт); подсвечивается в тексте.
  String _searchQuery = '';

  /// Вложения, уже сохранённые в папку Nexus (кнопка «Загрузить» — один раз).
  Set<String> _saved = {};

  /// Большие вложения, которые сейчас скачиваются с сервера.
  final Set<String> _downloading = {};

  /// Нажатие на ярлык файла: открывает его внутри приложения. Файл с
  /// сервера (большой) при первом нажатии скачивается незаметно — без
  /// уведомлений, только крутится индикатор на ярлыке, — дальше только
  /// открывается.
  Future<void> _openAttachment(ChatMessage m) async {
    if (_downloading.contains(m.id)) return;
    try {
      var msg = m;
      if (msg.attachmentBase64 == null &&
          !(msg.attachmentLocalPath != null &&
              File(msg.attachmentLocalPath!).existsSync()) &&
          msg.driveFileId != null) {
        setState(() => _downloading.add(m.id));
        try {
          final dir = await getApplicationDocumentsDirectory();
          final destPath = p.join(dir.path, 'chat_downloads',
              '${m.clientMessageId}_${m.attachmentName ?? 'file'}');
          await Directory(p.dirname(destPath)).create(recursive: true);
          await widget.sync.downloadLargeAttachment(m, destPath: destPath);
        } finally {
          if (mounted) setState(() => _downloading.remove(m.id));
        }
        _reload();
        msg = widget.repo.forContact(_contact.id).firstWhere((x) => x.id == m.id, orElse: () => m);
      }
      final bytes = await _attachmentBytes(msg);
      if (bytes == null || !mounted) return;
      await AttachmentViewer.open(context,
          name: msg.attachmentName ?? 'file', bytes: bytes, mime: msg.attachmentMime);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не удалось открыть файл: {e}', {'e': friendlyError(e)}))));
      }
    }
  }

  Future<Uint8List?> _attachmentBytes(ChatMessage m) async {
    if (m.attachmentBase64 != null) return base64Decode(m.attachmentBase64!);
    final path = m.attachmentLocalPath;
    if (path != null && File(path).existsSync()) return File(path).readAsBytes();
    return null;
  }

  /// «Загрузить»: переносит вложение в папку Nexus (галерея или «Загрузки»)
  /// без вопросов и без уведомления; кнопка после этого исчезает.
  Future<void> _saveAttachment(ChatMessage m) async {
    final name = m.attachmentName ?? 'file';
    bool ok;
    final path = m.attachmentLocalPath;
    if (m.attachmentBase64 == null && path != null) {
      ok = await saveFileToAppFolder(path, name, m.attachmentMime);
    } else if (m.attachmentBase64 != null) {
      ok = await saveToAppFolder(base64Decode(m.attachmentBase64!), name, m.attachmentMime);
    } else {
      return;
    }
    if (!mounted) return;
    if (ok) {
      widget.repo.markSaved(m.clientMessageId);
      setState(() => _saved = widget.repo.savedFor(_contact.id));
    } else {
      _toastSaved(context, false);
    }
  }

  void _reply(ChatMessage m) => setState(() => _replyingTo = m);

  Future<void> _copySelected() async {
    final ordered = _messages.where((m) => _selected.contains(m.id));
    final text = ordered
        .map((m) => m.text ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    setState(() => _selected.clear());
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Скопировано'))));
  }

  /// Кнопка «Перевести» — переключатель: перевод показывается под оригиналом;
  /// нажатие на уже включённый перевод выключает его. Выбор не сбрасывается,
  /// чтобы было видно состояние кнопки (активна — перевод включён).
  Future<void> _translateSelected() async {
    final msgs = [
      for (final m in _messages)
        if (_selected.contains(m.id) && m.text != null && m.text!.isNotEmpty) m
    ];
    if (msgs.isEmpty) return;
    if (_selectionTranslated) {
      setState(() {
        for (final m in msgs) {
          _maskOverride[m.id] = false;
        }
      });
      return;
    }
    await Future.wait([
      for (final m in msgs)
        if (!_translations.containsKey(m.id)) _translate(m),
    ]);
    if (!mounted) return;
    setState(() {
      for (final m in msgs) {
        _maskOverride[m.id] = true;
      }
    });
  }

  /// Перевод включён у всех выбранных сообщений (состояние кнопки).
  bool get _selectionTranslated {
    final msgs = [
      for (final m in _messages)
        if (_selected.contains(m.id) && m.text != null && m.text!.isNotEmpty) m
    ];
    return msgs.isNotEmpty &&
        msgs.every((m) => _isMasked(m) && _translations.containsKey(m.id));
  }

  /// Кнопки действий над выбранным: вертикальный столбик круглых кнопок справа,
  /// выезжающих сверху вниз; тень едет вместе с кнопкой и падает вверх и вправо.
  Widget _selectionActions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final single = _singleSelectedMessage();
    final items = <({IconData icon, String tip, VoidCallback onTap, bool active, bool danger})>[
      (icon: Icons.copy_outlined, tip: tr('Копировать'), onTap: _copySelected, active: false, danger: false),
      (icon: Icons.translate_outlined, tip: tr('Перевести'), onTap: _translateSelected, active: _selectionTranslated, danger: false),
      if (single != null) ...[
        (icon: Icons.reply_outlined, tip: tr('Ответить'), onTap: _replySelected, active: false, danger: false),
        if (single.direction == ChatMessageDirection.outgoing && single.type == ChatMessageType.text)
          (icon: Icons.edit_outlined, tip: tr('Редактировать'), onTap: _editSelected, active: false, danger: false),
        if (single.direction == ChatMessageDirection.outgoing && single.status == ChatMessageStatus.error)
          (icon: Icons.refresh, tip: tr('Отправить ещё раз'), onTap: _retrySelected, active: false, danger: false),
      ],
      (icon: Icons.delete_outline, tip: tr('Удалить'), onTap: _deleteSelected, active: false, danger: true),
    ];
    return Positioned(
      right: 12,
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
      child: Column(
        key: const ValueKey('selection-actions'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, it) in items.indexed)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 220 + i * 60),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(
                opacity: v.clamp(0.0, 1.0),
                // Кнопка и её тень — один виджет: тень выезжает вместе с ней.
                child: Transform.translate(offset: Offset(0, -28 * (1 - v)), child: child),
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.38),
                          blurRadius: 10,
                          offset: const Offset(4, -3)),
                    ],
                  ),
                  child: GlassCircleButton(
                    tooltip: it.tip,
                    onTap: it.onTap,
                    color: it.active ? cs.primary.withValues(alpha: 0.9) : null,
                    icon: Icon(it.icon,
                        color: it.active
                            ? cs.onPrimary
                            : it.danger
                                ? cs.error
                                : null),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
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
    final canForAll = chosen
        .where((m) =>
            m.direction == ChatMessageDirection.outgoing && !m.readByPeer)
        .length;
    final read = chosen
        .where(
            (m) => m.direction == ChatMessageDirection.outgoing && m.readByPeer)
        .length;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(chosen.length == 1
            ? tr('Удалить сообщение?')
            : tr('Удалить {length} сообщ.?', {'length': chosen.length})),
        content: canForAll == 0
            ? Text(read > 0
                ? tr('Собеседник уже прочитал — удалить можно только у себя.')
                : tr('Удалится только у вас.'))
            : Text(read > 0
                ? tr('Уже прочитанные ({read}) удалятся только у вас.',
                    {'read': read})
                : tr('Можно удалить и у собеседника — он ещё не прочитал.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('me'),
              child: Text(tr('У меня'))),
          if (canForAll > 0)
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop('all'),
                child: Text(tr('У всех'))),
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
        title: Text(tr('Изменить сообщение')),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 4),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(tr('Сохранить'))),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == m.text) return;
    await widget.sync.editMessage(m, newText);
    _reload();
  }

  Future<void> _delete(ChatMessage m, {bool forAll = false}) async {
    final mine = m.direction == ChatMessageDirection.outgoing;
    await widget.sync
        .deleteMessage(m, alsoRemote: forAll && mine && !m.readByPeer);
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
          content: Text(tr('Слишком большой файл — до {p}', {
            'p': ChatMediaUtils.formatSize(ChatMediaUtils.maxAttachmentBytes)
          })),
        ));
      }
      return;
    }

    final isImage = ChatMediaUtils.looksLikeImage(picked.name);
    final result = await Navigator.of(context)
        .push<AttachmentComposeResult>(MaterialPageRoute(
      builder: (_) => AttachmentComposeScreen(
          bytes: bytes, fileName: picked.name, isImage: isImage),
    ));
    if (result == null) return; // экран закрыли без отправки
    final finalBytes =
        result.bytes; // те же байты либо отредактированные в компоузере

    setState(() => _sending = true);
    try {
      final compressed =
          isImage ? ChatMediaUtils.compressImage(finalBytes) : null;
      await widget.sync.sendAttachment(
        contactId: _contact.id,
        bytes: compressed ?? finalBytes,
        fileName: picked.name,
        // Сжатие всегда перекодирует в JPEG (см. ChatMediaUtils.compressImage)
        // — mime должен это отражать, а не оставаться от исходного .png/.webp.
        mime: isImage
            ? (compressed != null
                ? 'image/jpeg'
                : ChatMediaUtils.mimeFor(picked.name))
            : 'application/octet-stream',
        type: isImage ? ChatMessageType.image : ChatMessageType.file,
        caption: result.caption.isEmpty ? null : result.caption,
        downloadAllowed:
            widget.prefs.downloadAllowedFor(isPersonal: !_contact.isGroup),
      );
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
      }
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
        downloadAllowed:
            widget.prefs.downloadAllowedFor(isPersonal: !_contact.isGroup),
      );
      _scrollToEnd();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не отправлено: {e}', {'e': friendlyError(e)}))));
      }
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

  /// Колокольчик в шапке встроенной переписки: вызов этого тренера
  /// (громкий push с кнопкой «Иду», см. `ChatSyncService.sendCall`).
  Future<void> _callCoach() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.sync.sendCall(_contact.id);
      messenger.showSnackBar(SnackBar(
          content: Text(tr('{p} получит вызов', {'p': _contact.nickname}))));
      _reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content:
              Text(tr('Не удалось позвать: {e}', {'e': friendlyError(e)}))));
    }
  }

  /// Шапка — отдельные стеклянные плитки поверх ленты, а не полоса.
  PreferredSizeWidget _glassHeader(BuildContext context) {
    final theme = Theme.of(context);
    return GlassHeader(
      onTitleTap: _openPanel,
      leading: widget.embedded ? const SizedBox.shrink() : null,
      actions: [
        GlassCircleButton(
          icon: const Icon(Icons.search),
          tooltip: tr('Поиск по переписке'),
          onTap: _openSearch,
        ),
        const SizedBox(width: 6),
        if (widget.embedded)
          GlassCircleButton(
            icon: const BoldIcon(Icons.notifications_active_outlined),
            tooltip: tr('Вызвать тренера'),
            onTap: _callCoach,
          )
        else
          GlassCircleButton(
            icon: const BoldIcon(Icons.close),
            tooltip: tr('Свернуть мессенджер'),
            onTap: () => ChatHomeScreen.close(context),
          ),
      ],
      titlePadding: const EdgeInsets.fromLTRB(4, 4, 18, 4),
      title: ValueListenableBuilder(
        valueListenable: ChatPresence.seen,
        builder: (context, _, __) {
          final online = !_contact.isGroup &&
              (_live?.peerOnline == true || ChatPresence.online(_contact.id));
          final seen = _contact.isGroup
              ? null
              : (online ? tr('в сети') : ChatPresence.label(_contact.id));
          return Row(
            children: [
              ChatAvatar(
                base64: _contact.avatarBase64,
                nickname: _contact.nickname,
                radius: 20,
                background:
                    _contact.isGroup ? chatGroupColor(_contact.color) : null,
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
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (_contact.isGroup)
                      Text(
                        (_groupLive?.onlineCount ?? 0) > 1
                            ? tr('Участников: {length}, в сети: {online}', {
                                'length': _contact.members.length,
                                'online': _groupLive!.onlineCount
                              })
                            : tr('Участников: {length}',
                                {'length': _contact.members.length}),
                        style: theme.textTheme.bodySmall,
                      )
                    else if (seen != null)
                      // «О себе» тут не показываем — только на странице собеседника
                      // (ChatContactPanelScreen), решение пользователя.
                      Text(seen,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: online ? const Color(0xFF3DDC84) : null)),
                  ],
                ),
              ),
              if (!_contact.isGroup)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: LinkSignal(
                    mode: linkMode(
                      direct: _live?.isDirect == true,
                      live: _live?.peerOnline == true,
                    ),
                  ),
                ),
              if (widget.prefs.mutedFor(_contact.id))
                Icon(Icons.notifications_off_outlined,
                    size: 18, color: theme.hintColor),
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
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.35),
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: SingleChildScrollView(
                        child: AiChartView(spec: _pendingChart!))),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: tr('Убрать график'),
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
                  ? tr('Ответ себе')
                  : tr('Ответ {p}', {
                      'p': _contact.isGroup
                          ? (_contact
                                  .member(_replyingTo!.senderId ?? '')
                                  ?.nickname ??
                              '')
                          : _contact.nickname
                    }),
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
                    radius:
                        25, // постоянное — многострочный текст не раздувает скругление
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          onPressed: _toggleEmoji,
                          tooltip:
                              _emojiOpen ? tr('Клавиатура') : tr('Смайлики'),
                          icon: Icon(_emojiOpen
                              ? Icons.keyboard_outlined
                              : Icons.emoji_emotions_outlined),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              hintText: tr('Сообщение'),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed:
                              _sending || _aiBusy ? null : _composeWithAi,
                          tooltip: tr('Написать с ИИ'),
                          icon: _aiBusy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.auto_awesome_outlined),
                        ),
                        GestureDetector(
                          // Долгое нажатие — большой файл через Google Drive,
                          // в обход лимита обычных вложений (см. `_attachLarge`).
                          onLongPress: _sending ? null : _attachLarge,
                          child: IconButton(
                            onPressed: _sending ? null : _attach,
                            icon: const Icon(Icons.attach_file),
                            tooltip: tr(
                                'Прикрепить фото или файл (долгое нажатие — большой файл)'),
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
      if (mounted && h != null && (h - _barHeight).abs() > 1)
        setState(() => _barHeight = h);
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
                  leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _selected.clear())),
                  title: Text('${_selected.length}'),
                )
              : (_searching ? _searchHeader(context) : _glassHeader(context)),
          // resizeToAvoidBottomInset выключен намеренно — Scaffold сам иногда
          // не отыгрывает обратное схлопывание после закрытия клавиатуры
          // системным жестом "назад" (а не тапом), оставляя пустой отступ.
          // AnimatedPadding реагирует на MediaQuery сам, на каждой перестройке,
          // и не завязан на то, как именно клавиатуру закрыли.
          resizeToAvoidBottomInset: false,
          body: AnimatedPadding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom),
            duration: const Duration(milliseconds: 100),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: widget.prefs.wallpaperDecoration,
                    child: Stack(
                      children: [
                        _messages.isEmpty
                            ? EmptyState(
                                icon: Icons.forum_outlined,
                                text: tr('Переписки пока нет'))
                            // Перевёрнутая лента: низ (новые) закреплён — при
                            // открытии клавиатуры последние сообщения остаются
                            // видны, а подгрузка картинок выше не сдвигает экран.
                            : ScrollablePositionedList.builder(
                                itemScrollController: _itemCtl,
                                itemPositionsListener: _itemPos,
                                reverse: true,
                                padding: EdgeInsets.fromLTRB(
                                    12,
                                    _selecting ? 12 : topInset,
                                    12,
                                    _barHeight + 8),
                                itemCount: _messages.length,
                                itemBuilder: (context, i) {
                                  final idx = _messages.length - 1 - i;
                                  final m = _messages[idx];
                                  final item = _item(m);
                                  // Первое сообщение дня — плашка с датой над ним (как в Telegram).
                                  if (idx > 0 &&
                                      _sameDay(_messages[idx - 1].createdAt,
                                          m.createdAt)) return item;
                                  return Column(
                                      children: [_dayChip(m.createdAt), item]);
                                },
                              ),
                        // Лента уходит под шапку и поле ввода с мягким затемнением.
                        Positioned.fill(
                          child: EdgeShade(
                              top: _selecting ? 0 : topInset + 16,
                              bottom: _barHeight + 24),
                        ),
                        Positioned(
                          right: 12,
                          bottom: _barHeight + 12,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _showJumpToEnd,
                            builder: (_, show, __) => show
                                ? GlassCircleButton(
                                    size: 44,
                                    onTap: _scrollToEnd,
                                    icon: const Icon(Icons.arrow_downward))
                                : const SizedBox.shrink(),
                          ),
                        ),
                        if (_selecting) _selectionActions(context),
                        Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _glassComposer(context)),
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
                        iconColorSelected:
                            Theme.of(context).colorScheme.primary,
                        backspaceColor: Theme.of(context).colorScheme.primary,
                      ),
                      bottomActionBarConfig:
                          const BottomActionBarConfig(enabled: false),
                      searchViewConfig: SearchViewConfig(
                        backgroundColor: Theme.of(context).colorScheme.surface,
                        hintText: tr('Поиск'),
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
    /*tr*/ 'января',
    /*tr*/ 'февраля',
    /*tr*/ 'марта',
    /*tr*/ 'апреля',
    /*tr*/ 'мая',
    /*tr*/ 'июня',
    /*tr*/ 'июля',
    /*tr*/ 'августа',
    /*tr*/ 'сентября',
    /*tr*/ 'октября',
    /*tr*/ 'ноября',
    /*tr*/ 'декабря',
  ];

  /// «Сегодня» / «Вчера» / «26 сентября» (другой год — «26 сентября 2025»).
  static String dayLabel(DateTime t, DateTime now) {
    final d = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return tr('Сегодня');
    if (diff == 1) return tr('Вчера');
    final base = '${t.day} ${tr(_months[t.month - 1])}';
    return t.year == now.year ? base : '$base ${t.year}';
  }

  Widget _dayChip(DateTime t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: GlassPill(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Text(dayLabel(t.toLocal(), DateTime.now()),
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Widget _item(ChatMessage m) {
    final selected = _selected.contains(m.id);
    final mine = m.direction == ChatMessageDirection.outgoing;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Dismissible(
        key: ValueKey(m.id),
        direction:
            _selecting ? DismissDirection.none : DismissDirection.startToEnd,
        // Свайп только показывает жест "ответить" и всегда возвращает пузырь
        // на место (решение пользователя: ответ свайпом за само сообщение).
        confirmDismiss: (_) async {
          _reply(m);
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Icon(Icons.reply_outlined,
              color: Theme.of(context).colorScheme.primary),
        ),
        child: GestureDetector(
          onTap: _selecting ? () => _toggleSelect(m.id) : null,
          onLongPress: () => _toggleSelect(m.id),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                  : null,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Bubble(
                  message: m,
                  prefs: widget.prefs,
                  senderName: _contact.isGroup &&
                          m.direction == ChatMessageDirection.incoming
                      ? (_contact.member(m.senderId ?? '')?.nickname ?? '—')
                      : null,
                  translation: _translations[m.id],
                  masked: _isMasked(m),
                  translating: _translating.contains(m.id),
                  translationError: _translationErrors[m.id],
                  onRetry: () => _retry(m),
                  onAckCall: () => _ackCall(m),
                  onCancelCall: () => _cancelCall(m),
                  onOpenFile: () => _openAttachment(m),
                  onSave: () => _saveAttachment(m),
                  saved: _saved.contains(m.clientMessageId),
                  downloading: _downloading.contains(m.id),
                  highlight: _searchQuery,
                ),
                _reactionChips(m),
                // Выбрано одно сообщение — панель реакций прямо под ним.
                if (_selected.length == 1 && selected)
                  ReactionBar(
                    key: ValueKey('react-${m.id}'),
                    recent: widget.prefs.recentReactions,
                    mine: _reactions[m.clientMessageId]?[widget.auth.userId],
                    onPick: (e) {
                      widget.prefs.addRecentReaction(e);
                      setState(() => _selected.clear());
                      _react(m, e);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Текст с подсвеченными совпадениями со словом поиска по чату (без учёта
/// регистра и ё/е).
Widget _highlightedText(String text, TextStyle? style, String query) {
  if (query.isEmpty) return Text(text, style: style);
  String norm(String t) => t.toLowerCase().replaceAll('ё', 'е');
  final hay = norm(text), needle = norm(query);
  if (hay.length != text.length || needle.isEmpty || !hay.contains(needle)) {
    return Text(text, style: style);
  }
  final spans = <TextSpan>[];
  var from = 0;
  while (true) {
    final i = hay.indexOf(needle, from);
    if (i < 0) break;
    if (i > from) spans.add(TextSpan(text: text.substring(from, i)));
    spans.add(TextSpan(
        text: text.substring(i, i + needle.length),
        style: const TextStyle(
            backgroundColor: Color(0xAAFFC107), color: Colors.black)));
    from = i + needle.length;
  }
  if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
  return Text.rich(TextSpan(style: style, children: spans));
}

/// Сохранение в папку Nexus идёт без уведомления; сообщаем только о неудаче.
void _toastSaved(BuildContext context, bool ok) {
  if (ok) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(tr('Не удалось сохранить файл'))));
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
  final VoidCallback onOpenFile;

  /// Сохранить вложение в папку Nexus (кнопка «Загрузить», один раз).
  final VoidCallback onSave;

  /// Вложение уже сохранено — кнопка «Загрузить» больше не показывается.
  final bool saved;

  /// Большой файл сейчас скачивается с сервера.
  final bool downloading;

  /// Слово поиска по чату — подсвечивается в тексте.
  final String highlight;

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
    required this.onOpenFile,
    required this.onSave,
    required this.saved,
    required this.downloading,
    required this.highlight,
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
        'acknowledged' => mine ? tr('Тренер идёт') : tr('Вы согласились идти'),
        'cancelled' =>
          mine ? tr('Вызов отменён') : tr('Пропущенный — помощь не нужна'),
        _ => mine ? tr('Вы позвали') : tr('Вас позвали'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.direction == ChatMessageDirection.outgoing;
    final isError = message.status == ChatMessageStatus.error;
    final base = isError
        ? cs.errorContainer
        : (mine ? prefs.mineBubbleColor : prefs.otherBubbleColor);
    final fg = isError
        ? cs.onErrorContainer
        : (mine ? prefs.mineTextColor : prefs.otherTextColor);
    // График (```chart) рисуется отдельной карточкой над пузырём.
    final (captionText, chart) =
        message.text == null ? ('', null) : AiService.splitChart(message.text!);
    final hasCaption = captionText.isNotEmpty;
    final radius = prefs.bubbleRadius;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: fg,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * prefs.fontScale,
    );
    final isImage = message.type == ChatMessageType.image &&
        message.attachmentBase64 != null;
    // Фото без подписи — совсем без рамки/фона (решение пользователя):
    // рамка появляется, только только когда под фото есть что оборачивать
    // (подпись или цитата ответа).
    final isBareImage =
        isImage && !hasCaption && message.replyToPreview == null;

    final decoration = BoxDecoration(
      // Лёгкий градиент вместо плоской заливки — тот самый "3D"-эффект
      // (пункт 7): верх чуть светлее, низ чуть темнее.
      gradient: bubbleGradient(base),
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
              border: Border(
                  left: BorderSide(color: fg.withValues(alpha: 0.5), width: 3)),
            ),
            child: Text(
              message.replyToPreview!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: fg.withValues(alpha: 0.85)),
            ),
          ),
        ],
        if (!isImage && message.type == ChatMessageType.file) ...[
          // Ярлык файла: расширение на кнопке, название снизу. Нажатие
          // открывает файл внутри приложения (большой файл с сервера при
          // первом нажатии скачивается незаметно). Кнопка «Загрузить»
          // (сохранить в папку Nexus) показывается один раз.
          FileChip(
            name: message.attachmentName ?? tr('Файл'),
            size: message.attachmentSize,
            fg: fg,
            remote: message.attachmentBase64 == null &&
                message.attachmentLocalPath == null &&
                message.driveFileId != null,
            busy: downloading,
            onSave: !mine &&
                    message.downloadAllowed &&
                    !saved &&
                    (message.attachmentBase64 != null ||
                        message.attachmentLocalPath != null)
                ? onSave
                : null,
            onTap: (mine || message.downloadAllowed || message.attachmentBase64 != null)
                ? onOpenFile
                : null,
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
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: fg, fontWeight: FontWeight.w600),
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
                      style: TextButton.styleFrom(
                          foregroundColor: fg, padding: EdgeInsets.zero),
                      onPressed: onCancelCall,
                      child: Text(tr('Отменить')),
                    )
                  : FilledButton(
                      onPressed: onAckCall,
                      child: Text(tr('Иду')),
                    ),
            ),
          ],
        ],
        // Перевод показывается ПОД оригиналом (если он отличается от него:
        // совпавший текст — тот же язык — не дублируем).
        if (hasCaption)
          // Text, не SelectableText — своё выделение перехватывало долгое
          // нажатие раньше меню действий (мешало открыть его на
          // Android). Копирование теперь только через меню.
          // Пока идёт перевод — оригинал чуть бледнее, высота не меняется.
          Opacity(
              opacity: translating ? 0.6 : 1,
              child: _highlightedText(captionText, textStyle, highlight)),
        if (masked &&
            translation != null &&
            translation!.trim().isNotEmpty &&
            translation!.trim() != captionText.trim()) ...[
          const SizedBox(height: 4),
          Divider(height: 1, thickness: 0.6, color: fg.withValues(alpha: 0.25)),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 4),
                child: Icon(Icons.translate_outlined,
                    size: 13, color: fg.withValues(alpha: 0.7)),
              ),
              Flexible(
                child: Text(translation!, style: textStyle),
              ),
            ],
          ),
        ],
      ],
    );

    // «Скачать» — только получателю (у отправителя фото и так есть);
    // «Поделиться» (переслать в другое приложение) — обоим, если разрешено.
    Widget roundAction(IconData icon, String tip, VoidCallback onTap) =>
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Tooltip(
                message: tip,
                child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(icon, color: Colors.white, size: 18)),
              ),
            ),
          ),
        );

    Widget withDownloadButton(Widget image) {
      final canDownload = !mine && message.downloadAllowed;
      final canShare = mine || message.downloadAllowed;
      if (!canDownload && !canShare) return image;
      final name = message.attachmentName ?? 'photo.jpg';
      return Stack(
        children: [
          image,
          Positioned(
            right: 6,
            bottom: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canShare)
                  roundAction(
                      Icons.share_outlined,
                      tr('Поделиться'),
                      () => ChatMediaUtils.shareAttachment(
                          base64Decode(message.attachmentBase64!),
                          name,
                          message.attachmentMime)),
                if (canDownload && !saved)
                  roundAction(Icons.download_outlined, tr('Скачать'), onSave),
              ],
            ),
          ),
        ],
      );
    }

    void openFullscreen() {
      PhotoViewerScreen.open(context,
          ChatMediaUtils.imageOf(message.id, message.attachmentBase64!));
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
                image: ChatMediaUtils.imageOf(
                    message.id, message.attachmentBase64!),
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
                      image: ChatMediaUtils.imageOf(
                          message.id, message.attachmentBase64!),
                      fit: BoxFit.cover,
                      gaplessPlayback: true),
                ),
              )),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: decoration.copyWith(
                  borderRadius:
                      BorderRadius.vertical(bottom: Radius.circular(radius))),
              child: captionContent,
            ),
          ],
        ),
      );
    } else {
      frame = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration:
            decoration.copyWith(borderRadius: BorderRadius.circular(radius)),
        child: captionContent,
      );
    }

    // Уровень загрузки вложения поверх превью — вместо мгновенного
    // «залипания» на статусе «отправляется» до внезапного «отправлено»
    // (решение пользователя). Фото/файл и так уже видно из локальных
    // байт сразу же, тут только индикатор поверх него.
    final framedWithProgress = mine &&
            message.status == ChatMessageStatus.sending &&
            message.attachmentBase64 != null
        ? ValueListenableBuilder<Map<String, double>>(
            valueListenable: ChatSyncService.uploadProgress,
            builder: (context, progress, _) {
              final p = progress[message.clientMessageId];
              if (p == null) return frame;
              return Stack(
                alignment: Alignment.center,
                children: [
                  frame,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child:
                        Container(color: Colors.black.withValues(alpha: 0.35)),
                  ),
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                        strokeWidth: 3, value: p, color: Colors.white),
                  ),
                  Text('${(p * 100).round()}%',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ],
              );
            },
          )
        : frame;

    // Без Align: место в строке задаёт _item — тогда свайп ловит только пузырь.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // Рамка — только содержимое сообщения. Дата, статус и пометка
        // "изменено" вынесены НАРУЖУ, тем же краем, что и сам пузырь
        // (решение пользователя, пункт 2 списка правок).
        if (chart != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AiChartView(spec: chart),
          ),
        if (hasCaption ||
            chart == null ||
            message.replyToPreview != null ||
            senderName != null)
          framedWithProgress,
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.edited) ...[
                Text(tr('изменено'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.hintColor)),
                const SizedBox(width: 6),
              ],
              Text(
                DateFormat('HH:mm').format(message.createdAt.toLocal()),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.hintColor),
              ),
              if (mine) ...[
                const SizedBox(width: 6),
                // Одна серая ✓ — дошло (на сервере или уже на устройстве, но
                // не прочитано), синие ✓✓ — прочитано. Промежуточного
                // «доставлено, но двумя галочками» нет — путает с «прочитано».
                Icon(
                  message.readByPeer
                      ? Icons.done_all
                      : _statusIcon(message.status),
                  size: 14,
                  color: message.readByPeer
                      ? const Color(0xFF34B7F1)
                      : theme.hintColor,
                ),
              ],
              if (translationError != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTapDown: (d) => showChatErrorBubble(
                      context, d.globalPosition, translationError!),
                  child: const Icon(Icons.translate_outlined,
                      size: 13, color: Colors.red),
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
            label: Text(tr('Отправить ещё раз')),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          ),
        ],
        const SizedBox(height: 5),
      ],
    );
  }

  IconData _statusIcon(ChatMessageStatus s) => switch (s) {
        ChatMessageStatus.sending => Icons.schedule,
        ChatMessageStatus.sent => Icons.check,
        ChatMessageStatus.delivered =>
          Icons.check, // дошло, но не прочитано — одна галочка
        ChatMessageStatus.error => Icons.error_outline,
      };
}
