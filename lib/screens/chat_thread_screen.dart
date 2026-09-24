import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logic/adaptive_poller.dart';
import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/chat_translation_service.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/chat_quick_menu.dart';
import '../widgets/chat_reply_bar.dart';
import '../widgets/empty_state.dart';
import 'attachment_compose_screen.dart';
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
  final _input = TextEditingController();
  final _scroll = ScrollController();
  PollLoop? _pollLoop;
  List<ChatMessage> _messages = [];
  bool _sending = false;
  ChatMessage? _replyingTo;

  /// Кнопка "вниз к недавним" — появляется, когда прокрутили далеко
  /// вверх по истории.
  bool _showJumpToEnd = false;

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
  static const int _translateBatch = 10;
  int _translateVisibleCount = _translateBatch;
  String _lastTranslationLanguage = '';

  bool _isMasked(ChatMessage m) {
    final override = _maskOverride[m.id];
    if (override != null) return override;
    return widget.prefs.autoTranslate &&
        m.direction == ChatMessageDirection.incoming &&
        _translations.containsKey(m.id);
  }

  @override
  void initState() {
    super.initState();
    _lastTranslationLanguage = widget.prefs.translationLanguage;
    widget.prefs.addListener(_onPrefsChanged);
    widget.repo.markThreadSeen(widget.contact.id);
    _reload();
    _scroll.addListener(_onScroll);
    // Адаптивный опрос: пока собеседник пишет — каждые 5 секунд, в тишине
    // растёт до 30 (см. AdaptivePoller). Отправка своего сообщения возвращает
    // частый режим — ответ обычно приходит скоро.
    _pollLoop = PollLoop(
      poller: AdaptivePoller(min: const Duration(seconds: 5), max: const Duration(seconds: 30)),
      tick: () async {
        final added = await widget.sync.pollIncoming();
        if (added > 0 && mounted) {
          widget.repo.markThreadSeen(widget.contact.id);
          _reload();
          _scrollToEnd();
        }
        return added > 0;
      },
    )..start();
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefsChanged);
    _pollLoop?.stop();
    _input.dispose();
    _scroll.dispose();
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
      if (widget.prefs.autoTranslate) _autoTranslateIncoming();
    } else {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final jump = _scroll.position.pixels < _scroll.position.maxScrollExtent - 400;
    if (jump != _showJumpToEnd) setState(() => _showJumpToEnd = jump);
    if (_translateVisibleCount >= _messages.length) return;
    if (_scroll.position.pixels <= _scroll.position.minScrollExtent + 200) {
      _translateVisibleCount += _translateBatch;
      if (widget.prefs.autoTranslate) _autoTranslateIncoming();
    }
  }

  void _reload() {
    setState(() => _messages = widget.repo.forContact(widget.contact.id));
    if (widget.prefs.autoTranslate) _autoTranslateIncoming();
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
      final translated =
          await _translator.translateIfNeeded(m.text!, targetLanguage: widget.prefs.translationLanguage);
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
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final replyTo = _replyingTo;
    _input.clear();
    setState(() {
      _sending = true;
      _replyingTo = null;
    });
    try {
      _pollLoop?.poller.nudge(); // ждём ответ — опрашиваем чаще
      await widget.sync.send(widget.contact.id, text, replyTo: replyTo);
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

  Future<void> _retry(ChatMessage m) async {
    try {
      await widget.sync.retry(m);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      _reload();
    }
  }

  /// "Позвать" — отдельная кнопка в шапке, не текстовое сообщение:
  /// собеседник получает push с усиленным звуком/вибрацией (см.
  /// `push_service.dart`), а не просто прочитает сообщение когда-нибудь.
  /// Была убрана из личного чата, пользователь попросил вернуть именно
  /// сюда (а не в отдельный режим тренировки).
  Future<void> _call() async {
    setState(() => _sending = true);
    try {
      await widget.sync.sendCall(widget.contact.id);
      _reload();
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось позвать: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
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

  /// Переписка на устройстве не трогается — удаляется только сама
  /// запись контакта (не будет в списке слева); написать снова можно
  /// через код или из общего чата, как и добавляли в первый раз.
  Future<void> _removeContact() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить из контактов?'),
        content: Text('Переписка с ${widget.contact.nickname} останется на устройстве, но сам контакт пропадёт из списка.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.repo.deleteContact(widget.contact.id);
    if (mounted) Navigator.of(context).pop();
  }

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

  Future<void> _deleteSelected() async {
    final ids = Set<String>.from(_selected);
    setState(() => _selected.clear());
    for (final m in _messages.where((m) => ids.contains(m.id)).toList()) {
      await _delete(m);
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

  Future<void> _delete(ChatMessage m) async {
    final mine = m.direction == ChatMessageDirection.outgoing;
    await widget.sync.deleteMessage(m, alsoRemote: mine);
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
        contactId: widget.contact.id,
        bytes: compressed ?? bytes,
        fileName: picked.name,
        // Сжатие всегда перекодирует в JPEG (см. ChatMediaUtils.compressImage)
        // — mime должен это отражать, а не оставаться от исходного .png/.webp.
        mime: isImage ? (compressed != null ? 'image/jpeg' : ChatMediaUtils.mimeFor(picked.name)) : 'application/octet-stream',
        type: isImage ? ChatMessageType.image : ChatMessageType.file,
        caption: caption.isEmpty ? null : caption,
        downloadAllowed: widget.prefs.downloadAllowedFor(isPersonal: true),
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
        contactId: widget.contact.id,
        filePath: picked.path,
        fileName: picked.name,
        mime: ChatMediaUtils.looksLikeImage(picked.name) ? ChatMediaUtils.mimeFor(picked.name) : 'application/octet-stream',
        type: ChatMessageType.file,
        fileSize: picked.size,
        downloadAllowed: widget.prefs.downloadAllowedFor(isPersonal: true),
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) => Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selected.clear())),
                title: Text('${_selected.length}'),
                actions: [
                  IconButton(icon: const Icon(Icons.copy_outlined), tooltip: 'Копировать', onPressed: _copySelected),
                  IconButton(
                      icon: const Icon(Icons.translate_outlined), tooltip: 'Перевести', onPressed: _translateSelected),
                  if (_singleSelectedMessage() case final single?) ...[
                    IconButton(icon: const Icon(Icons.reply_outlined), tooltip: 'Ответить', onPressed: _replySelected),
                    if (single.direction == ChatMessageDirection.outgoing && single.type == ChatMessageType.text)
                      IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Редактировать', onPressed: _editSelected),
                    if (single.direction == ChatMessageDirection.outgoing && single.status == ChatMessageStatus.error)
                      IconButton(icon: const Icon(Icons.refresh), tooltip: 'Отправить ещё раз', onPressed: _retrySelected),
                  ],
                  IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Удалить', onPressed: _deleteSelected),
                ],
              )
            : AppBar(
          title: Row(
            children: [
              ChatAvatar(base64: widget.contact.avatarBase64, nickname: widget.contact.nickname, radius: 16),
              const SizedBox(width: 10),
              Text(widget.contact.nickname),
            ],
          ),
          // Пока единственный пункт — удаление контакта (решение
          // пользователя: убрать эту возможность из списка "Участники" и
          // держать настройки конкретного контакта здесь, тут же со
          // временем появятся остальные).
          actions: [
            IconButton(
              onPressed: _sending ? null : _call,
              icon: const Icon(Icons.campaign_outlined),
              tooltip: 'Позвать',
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'remove') _removeContact();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'remove', child: Text('Удалить из контактов')),
              ],
            ),
          ],
        ),
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
              child: Stack(
                children: [
                  _messages.isEmpty
                      ? const EmptyState(icon: Icons.forum_outlined, text: 'Переписки пока нет')
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            final selected = _selected.contains(m.id);
                            return Dismissible(
                              key: ValueKey(m.id),
                              direction: _selecting ? DismissDirection.none : DismissDirection.startToEnd,
                              // Свайп только показывает жест "ответить" и
                              // всегда возвращает пузырь на место (решение
                              // пользователя: ответ свайпом за само
                              // сообщение, а не отдельной кнопкой).
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
                          },
                        ),
                  if (_showJumpToEnd)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        heroTag: 'thread_chat_jump_to_end',
                        onPressed: _scrollToEnd,
                        child: const Icon(Icons.arrow_downward),
                      ),
                    ),
                ],
              ),
            ),
            if (_replyingTo != null)
              ChatReplyBar(
                preview: ChatSyncService.previewOf(_replyingTo!),
                onCancel: () => setState(() => _replyingTo = null),
              ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                // Ниже на ~10% (решение пользователя) — было 8 сверху/снизу.
                padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
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
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(hintText: 'Сообщение', isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
          ],
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
  const _Bubble({
    required this.message,
    required this.prefs,
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
    final hasCaption = message.text != null && message.text!.isNotEmpty;
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
          ? [BoxShadow(color: Colors.black.withValues(alpha: prefs.shadowIntensity), blurRadius: 10, offset: const Offset(0, 4))]
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
                child: Text(translation!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ),
            ],
          ),
        ] else if (hasCaption)
          // Text, не SelectableText — своё выделение перехватывало долгое
          // нажатие раньше меню действий (мешало открыть его на
          // Android). Копирование теперь только через меню.
          Text(message.text!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
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
        builder: (_) => PhotoViewerScreen(image: MemoryImage(base64Decode(message.attachmentBase64!))),
      ));
    }

    final Widget frame;
    if (isBareImage) {
      frame = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: withDownloadButton(GestureDetector(
          onTap: openFullscreen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
            child: Image.memory(base64Decode(message.attachmentBase64!), fit: BoxFit.contain),
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: withDownloadButton(GestureDetector(
                onTap: openFullscreen,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _imageMaxWidth),
                  child: Image.memory(base64Decode(message.attachmentBase64!), fit: BoxFit.cover),
                ),
              )),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: decoration.copyWith(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16))),
              child: captionContent,
            ),
          ],
        ),
      );
    } else {
      frame = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: decoration.copyWith(borderRadius: BorderRadius.circular(16)),
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
          frame,
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
                  Icon(_statusIcon(message.status), size: 14, color: theme.hintColor),
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
