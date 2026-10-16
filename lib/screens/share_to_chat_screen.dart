import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n/i18n.dart';
import 'chat_thread_screen.dart';
import 'chat_home_screen.dart';
import '../logic/chat_media_utils.dart';
import '../logic/friendly_error.dart';
import '../models/chat_contact.dart';
import '../models/chat_message.dart';
import '../services/chat_auth_service.dart';
import '../services/demo_mode.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_preferences.dart';
import '../services/chat_settings.dart';
import '../services/chat_sync_service.dart';
import '../services/local_db_service.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/file_chip.dart';
import '../widgets/glass_pill.dart';

/// Файл, полученный из системного меню «Поделиться».
class SharedFile {
  final String path;
  final String? mime;
  const SharedFile(this.path, this.mime);

  String get name => p.basename(path);
  bool get isImage =>
      (mime?.startsWith('image/') ?? false) || ChatMediaUtils.looksLikeImage(name);
}

/// «Отправить в чат»: сверху — что отправляем (превью), ниже — список
/// собеседников; нажатие на собеседника отправляет всё ему.
class ShareToChatScreen extends StatefulWidget {
  final LocalDbService db;
  final List<SharedFile> files;
  const ShareToChatScreen({super.key, required this.db, required this.files});

  @override
  State<ShareToChatScreen> createState() => _ShareToChatScreenState();
}

class _ShareToChatScreenState extends State<ShareToChatScreen> {
  late final ChatAuthService _auth = ChatAuthService(widget.db);
  late final ChatMessagesRepository _repo = ChatMessagesRepository(widget.db);
  late final ChatPreferences _prefs = ChatPreferences(widget.db);
  late final List<ChatContact> _contacts = _repo.listContacts();
  bool _sending = false;

  Future<void> _sendTo(ChatContact c) async {
    setState(() => _sending = true);
    final sync = ChatSyncService(_auth, _repo);
    final allowed = _prefs.downloadAllowedFor(isPersonal: !c.isGroup);
    try {
      for (final f in widget.files) {
        final file = File(f.path);
        final size = await file.length();
        if (size > ChatMediaUtils.maxDriveBytes) {
          throw Exception(tr('Файл «{n}» больше 1,5 ГБ — через облако не отправить', {'n': f.name}));
        }
        if (size > ChatMediaUtils.maxAttachmentBytes) {
          // Большой файл — через Google Drive, без чтения в память.
          await sync.sendLargeAttachment(
            contactId: c.id,
            filePath: f.path,
            fileName: f.name,
            mime: f.mime ?? 'application/octet-stream',
            type: ChatMessageType.file,
            fileSize: size,
            downloadAllowed: allowed,
          );
          continue;
        }
        var bytes = await file.readAsBytes();
        var mime = f.mime ?? 'application/octet-stream';
        var type = ChatMessageType.file;
        if (f.isImage) {
          final compressed = ChatMediaUtils.compressImage(bytes);
          if (compressed != null) {
            bytes = compressed;
            mime = 'image/jpeg';
          } else if (mime == 'application/octet-stream') {
            mime = ChatMediaUtils.mimeFor(f.name);
          }
          type = ChatMessageType.image;
        }
        await sync.sendAttachment(
          contactId: c.id,
          bytes: bytes,
          fileName: f.name,
          mime: mime,
          type: type,
          downloadAllowed: allowed,
        );
      }
      if (!mounted) return;
      // Открываем переписку с тем, кому отправили: список чатов, поверх — чат
      // («назад» ведёт к списку), а не просто главный экран приложения.
      final nav = Navigator.of(context);
      nav.pushReplacement(MaterialPageRoute(builder: (_) => const ChatHomeScreen()));
      nav.push(MaterialPageRoute(
        builder: (_) => ChatThreadScreen(contact: c, auth: _auth, repo: _repo, sync: sync, prefs: _prefs),
      ));
    } catch (e, st) {
      if (mounted) {
        setState(() => _sending = false);
        DemoMode.reportError(context, tr('Не отправлено: {e}', {'e': friendlyError(e)}), 'ShareToChatScreen', e, st);
      }
    }
  }

  Widget _preview(SharedFile f, Color fg) {
    if (f.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(File(f.path), width: 84, height: 84, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => FileChip(name: f.name, fg: fg)),
      );
    }
    return FileChip(name: f.name, fg: fg);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final ready = ChatSettings.isConfigured && _auth.isSignedIn;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Отправить в чат'),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height + 8, bottom: 24),
        children: [
          SizedBox(
            height: 124,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final f in widget.files)
                  Padding(padding: const EdgeInsets.only(right: 10), child: _preview(f, fg)),
              ],
            ),
          ),
          const Divider(),
          if (!ready)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                tr('Чтобы отправлять файлы, войдите в мессенджер: Настройки → Модули → Мессенджер.'),
                textAlign: TextAlign.center,
              ),
            )
          else if (_contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(tr('Пока нет собеседников — добавьте их в мессенджере.'), textAlign: TextAlign.center),
            )
          else
            for (final c in _contacts)
              ListTile(
                enabled: !_sending,
                leading: ChatAvatar(base64: c.avatarBase64, nickname: c.nickname),
                title: Text(c.nickname, overflow: TextOverflow.ellipsis),
                subtitle: c.isGroup ? Text(tr('Группа')) : null,
                trailing: _sending ? null : const Icon(Icons.send_outlined),
                onTap: () => _sendTo(c),
              ),
          if (_sending) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}
