import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';

import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_sync_service.dart';
import '../services/chat_translation_service.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';

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
  Timer? _pollTimer;
  List<ChatMessage> _messages = [];
  bool _sending = false;
  ChatMessage? _replyingTo;

  /// Переводы по id сообщения — только в памяти экрана, не сохраняются:
  /// дешевле перевести заново, чем городить локальное хранилище ради
  /// текста, который и так живёт на устройстве получателя.
  final Map<String, String> _translations = {};
  final Set<String> _translating = {};

  /// "Маска" — показывать ли перевод ВМЕСТО оригинала (пункт из
  /// обсуждения). Явный выбор пользователя по конкретному сообщению
  /// (кнопка "Перевести" в меню — тумблер, а не одноразовое действие);
  /// пока выбора нет, действует умолчание режима: в "всегда автоматически"
  /// маска на входящих включена сама, в "по кнопке" — выключена.
  final Map<String, bool> _maskOverride = {};
  late final ChatTranslationService _translator = ChatTranslationService();

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
    widget.repo.markThreadSeen(widget.contact.id);
    _reload();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final added = await widget.sync.pollIncoming();
      if (added > 0 && mounted) {
        widget.repo.markThreadSeen(widget.contact.id);
        _reload();
        _scrollToEnd();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() => _messages = widget.repo.forContact(widget.contact.id));
    if (widget.prefs.autoTranslate) _autoTranslateIncoming();
  }

  /// Режим "всегда автоматически" — переводит новые входящие в фоне,
  /// без действия пользователя. Свои же сообщения не трогает: их язык
  /// человек и так знает — он их написал.
  void _autoTranslateIncoming() {
    for (final m in _messages) {
      if (m.direction != ChatMessageDirection.incoming) continue;
      if (m.text == null || m.text!.isEmpty) continue;
      if (_translations.containsKey(m.id) || _translating.contains(m.id)) continue;
      _translate(m, silent: true);
    }
  }

  Future<void> _translate(ChatMessage m, {bool silent = false}) async {
    if (m.text == null || m.text!.isEmpty) return;
    setState(() => _translating.add(m.id));
    try {
      final translated =
          await _translator.translateIfNeeded(m.text!, targetLanguage: widget.prefs.translationLanguage);
      if (!mounted) return;
      setState(() {
        if (translated != null) _translations[m.id] = translated;
        _translating.remove(m.id);
      });
    } catch (e) {
      _translating.remove(m.id);
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось перевести: $e')));
      }
    }
  }

  /// Кнопка "Перевести" в меню — тумблер маски, а не разовое действие:
  /// уже включена (по умолчанию режима "всегда" или включена вручную) —
  /// выключает; иначе переводит (если ещё не переведено) и включает.
  Future<void> _toggleMask(ChatMessage m) async {
    if (_isMasked(m)) {
      setState(() => _maskOverride[m.id] = false);
      return;
    }
    if (!_translations.containsKey(m.id)) await _translate(m);
    if (!mounted || !_translations.containsKey(m.id)) return;
    setState(() => _maskOverride[m.id] = true);
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
      await widget.sync.send(widget.contact.id, text, replyTo: replyTo);
      _reload();
      _scrollToEnd();
    } catch (e) {
      // Раньше необработанное исключение здесь означало, что сообщение
      // просто "пропадало" — текст уже очищен из поля, а _sending
      // навсегда оставался true (кнопка отправки переставала работать),
      // без единого следа для пользователя. Теперь ошибка видна и не
      // блокирует дальнейшую отправку.
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// "Позвать" — отдельная кнопка в шапке, не текстовое сообщение:
  /// собеседник получает push с усиленным звуком/вибрацией (см.
  /// sql/chat-schema.sql и Edge Function), а не просто прочитает
  /// сообщение когда-нибудь.
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

  Future<void> _retry(ChatMessage m) async {
    await widget.sync.retry(m);
    _reload();
  }

  void _reply(ChatMessage m) => setState(() => _replyingTo = m);

  void _copy(ChatMessage m) {
    if (m.text == null || m.text!.isEmpty) return;
    Clipboard.setData(ClipboardData(text: m.text!));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
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
    _reload();
  }

  /// Все действия над сообщением — одним долгим нажатием: копировать,
  /// повторить отправку, ответить, удалить, перевести (решение
  /// пользователя, вместо разрозненных кнопок/жестов на каждое
  /// действие по отдельности). Свайп по пузырю остаётся отдельным
  /// быстрым путём к "Ответить", меню его не заменяет, а дополняет.
  Future<void> _showMessageMenu(ChatMessage m) async {
    final mine = m.direction == ChatMessageDirection.outgoing;
    final canEdit = mine && m.type == ChatMessageType.text;
    final canCopy = m.text != null && m.text!.isNotEmpty;
    // Ручной перевод (тумблер маски) доступен всегда — настройка
    // "автоперевод" влияет только на то, замаскировано ли сообщение
    // ПО УМОЛЧАНИЮ, а не на доступность самой кнопки.
    final canTranslate = canCopy;
    final canRetry = mine && m.status == ChatMessageStatus.error;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать текст'),
                onTap: () => Navigator.of(ctx).pop('copy'),
              ),
            if (canRetry)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Отправить ещё раз'),
                onTap: () => Navigator.of(ctx).pop('retry'),
              ),
            ListTile(
              leading: const Icon(Icons.reply_outlined),
              title: const Text('Ответить'),
              onTap: () => Navigator.of(ctx).pop('reply'),
            ),
            if (canTranslate)
              ListTile(
                leading: Icon(Icons.translate_outlined, color: _isMasked(m) ? Theme.of(ctx).colorScheme.primary : null),
                title: const Text('Перевести'),
                trailing: _isMasked(m) ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null,
                onTap: () => Navigator.of(ctx).pop('translate'),
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Редактировать'),
                onTap: () => Navigator.of(ctx).pop('edit'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(mine ? 'Удалить' : 'Удалить у себя'),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'copy':
        _copy(m);
      case 'retry':
        await _retry(m);
      case 'reply':
        _reply(m);
      case 'translate':
        await _toggleMask(m);
      case 'edit':
        await _edit(m);
      case 'delete':
        await _delete(m);
    }
  }

  /// Прикрепить фото или файл — запись видео/голоса пока не встроена в
  /// интерфейс (см. комментарий у `ChatSyncService.sendAttachment`).
  /// Картинка сжимается перед отправкой (`ChatMediaUtils.compressImage`),
  /// остальные файлы уходят как есть.
  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.first;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;

    setState(() => _sending = true);
    try {
      final isImage = ChatMediaUtils.looksLikeImage(file.name);
      final compressed = isImage ? ChatMediaUtils.compressImage(bytes) : null;
      await widget.sync.sendAttachment(
        contactId: widget.contact.id,
        bytes: compressed ?? bytes,
        fileName: file.name,
        mime: isImage ? ChatMediaUtils.mimeFor(file.name) : 'application/octet-stream',
        type: isImage ? ChatMessageType.image : ChatMessageType.file,
      );
      _reload();
      _scrollToEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.prefs,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              ChatAvatar(base64: widget.contact.avatarBase64, nickname: widget.contact.nickname, radius: 16),
              const SizedBox(width: 10),
              Text(widget.contact.nickname),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _sending ? null : _call,
              icon: const Icon(Icons.campaign_outlined),
              tooltip: 'Позвать',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? const EmptyState(icon: Icons.forum_outlined, text: 'Переписки пока нет')
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        return Dismissible(
                          key: ValueKey(m.id),
                          direction: DismissDirection.startToEnd,
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
                            onLongPress: () => _showMessageMenu(m),
                            child: _Bubble(
                              message: m,
                              prefs: widget.prefs,
                              translation: _translations[m.id],
                              masked: _isMasked(m),
                              translating: _translating.contains(m.id),
                              onRetry: () => _retry(m),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_replyingTo != null) _ReplyPreviewBar(message: _replyingTo!, onCancel: () => setState(() => _replyingTo = null)),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: _sending ? null : _attach,
                      icon: const Icon(Icons.attach_file),
                      tooltip: 'Прикрепить фото или файл',
                    ),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(hintText: 'Сообщение'),
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
    );
  }
}

/// Полоска над полем ввода, пока выбран "ответ на сообщение" (свайп по
/// пузырю в списке) — цитата + крестик отмены, как в Telegram/WhatsApp.
class _ReplyPreviewBar extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onCancel;
  const _ReplyPreviewBar({required this.message, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 32, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ChatSyncService.previewOf(message),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
        ],
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
  final VoidCallback onRetry;
  const _Bubble({
    required this.message,
    required this.prefs,
    required this.translation,
    required this.masked,
    required this.translating,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.direction == ChatMessageDirection.outgoing;
    final isError = message.status == ChatMessageStatus.error;
    final base = isError ? cs.errorContainer : (mine ? prefs.mineBubbleColor : prefs.otherBubbleColor);
    final fg = isError ? cs.onErrorContainer : (mine ? prefs.mineTextColor : prefs.otherTextColor);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Рамка — только содержимое сообщения. Дата, статус и пометка
          // "изменено" вынесены НАРУЖУ, тем же краем, что и сам пузырь
          // (решение пользователя, пункт 2 списка правок).
          Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              // Лёгкий градиент вместо плоской заливки — тот самый
              // "3D"-эффект (пункт 7): верх чуть светлее, низ чуть темнее.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(base, Colors.white, 0.08)!, Color.lerp(base, Colors.black, 0.10)!],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: prefs.shadowEnabled
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: prefs.shadowIntensity),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Column(
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
                if (message.type == ChatMessageType.image && message.attachmentBase64 != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(base64Decode(message.attachmentBase64!), fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 6),
                ] else if (message.type == ChatMessageType.file) ...[
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
                    ],
                  ),
                  const SizedBox(height: 6),
                ] else if (message.type == ChatMessageType.call) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.campaign_outlined, color: fg),
                      const SizedBox(width: 8),
                      Text(
                        mine ? 'Вы позвали' : 'Вас позвали',
                        style: theme.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
                // "Маска" — перевод показывается ВМЕСТО оригинала, не
                // вместе с ним (решение пользователя): либо/либо, с
                // маленькой иконкой-подсказкой, что это перевод.
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
                        child: SelectableText(translation!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                      ),
                    ],
                  ),
                ] else if (message.text != null && message.text!.isNotEmpty)
                  SelectableText(message.text!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ],
            ),
          ),
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
