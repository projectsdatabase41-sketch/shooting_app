import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../logic/chat_media_utils.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_sync_service.dart';
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

  const ChatThreadScreen({
    super.key,
    required this.contact,
    required this.auth,
    required this.repo,
    required this.sync,
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

  void _reload() => setState(() => _messages = widget.repo.forContact(widget.contact.id));

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
    _input.clear();
    setState(() => _sending = true);
    await widget.sync.send(widget.contact.id, text);
    _reload();
    _scrollToEnd();
    setState(() => _sending = false);
  }

  Future<void> _retry(ChatMessage m) async {
    await widget.sync.retry(m);
    _reload();
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
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ChatAvatar(base64: widget.contact.avatarBase64, nickname: widget.contact.nickname, radius: 16),
            const SizedBox(width: 10),
            Text(widget.contact.nickname),
          ],
        ),
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
                    itemBuilder: (context, i) => _Bubble(message: _messages[i], onRetry: () => _retry(_messages[i])),
                  ),
          ),
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
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onRetry;
  const _Bubble({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.direction == ChatMessageDirection.outgoing;
    final bg = message.status == ChatMessageStatus.error
        ? cs.errorContainer
        : (mine ? cs.primaryContainer : cs.surfaceContainerHigh);
    final fg = message.status == ChatMessageStatus.error
        ? cs.onErrorContainer
        : (mine ? cs.onPrimaryContainer : cs.onSurface);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
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
            ],
            if (message.text != null && message.text!.isNotEmpty)
              SelectableText(message.text!, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('HH:mm').format(message.createdAt.toLocal()),
                  style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.65)),
                ),
                if (mine) ...[
                  const SizedBox(width: 6),
                  Icon(_statusIcon(message.status), size: 14, color: fg.withValues(alpha: 0.65)),
                ],
              ],
            ),
            if (mine && message.status == ChatMessageStatus.error) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Отправить ещё раз'),
                style: TextButton.styleFrom(
                  foregroundColor: fg,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ],
        ),
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
