import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../gdrive/chat_drive_backup.dart';
import '../gdrive/gdrive_service.dart';
import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/chat_backup_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_vault.dart';
import '../services/local_db_service.dart';
import '../services/supabase_auth_service.dart';
import '../widgets/glass_pill.dart';

/// «Сохранение переписок» (в настройках мессенджера): копия в личную базу с выбором частоты
/// и папка Nexus в памяти телефона, которая переживает удаление приложения.
class ChatBackupSettingsScreen extends StatefulWidget {
  final LocalDbService db;
  const ChatBackupSettingsScreen({super.key, required this.db});

  @override
  State<ChatBackupSettingsScreen> createState() => _ChatBackupSettingsScreenState();
}

class _ChatBackupSettingsScreenState extends State<ChatBackupSettingsScreen> {
  bool _backupBusy = false;
  String? _backupMessage;
  bool _vaultBusy = false;
  bool _driveBusy = false;
  String? _driveMessage;
  String? _vaultMessage;

  LocalDbService get db => widget.db;

  Future<void> _backupNow() async {
    final auth = SupabaseAuthService(db);
    if (!auth.hasBase) {
      setState(() => _backupMessage = tr('Сначала подключите свою базу: Настройки → Данные и синхронизация → Учётная запись'));
      return;
    }
    setState(() {
      _backupBusy = true;
      _backupMessage = null;
    });
    try {
      final n = await ChatBackupService(db, auth).run();
      if (mounted) setState(() => _backupMessage = n == 0 ? tr('Всё уже скопировано') : tr('Скопировано сообщений: {n}', {'n': n}));
    } catch (e) {
      if (mounted) setState(() => _backupMessage = friendlyError(e));
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _driveRun({required bool restore}) async {
    setState(() {
      _driveBusy = true;
      _driveMessage = null;
    });
    try {
      final b = ChatDriveBackup(db, GDriveService(db));
      final n = restore ? await b.restore(ChatMessagesRepository(db)) : await b.sync();
      if (mounted) {
        setState(() => _driveMessage = restore
            ? (n == 0 ? tr('На Диске нет ничего нового') : tr('Восстановлено сообщений: {n}', {'n': n}))
            : (n == 0 ? tr('Всё уже на Диске') : tr('Отправлено на Диск: {n}', {'n': n})));
      }
    } catch (e) {
      if (mounted) setState(() => _driveMessage = friendlyError(e));
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _vaultRun({required bool restore}) async {
    setState(() {
      _vaultBusy = true;
      _vaultMessage = null;
    });
    try {
      final n = restore ? await ChatVault.restore(db, ChatMessagesRepository(db)) : await ChatVault.sync(db);
      if (mounted) {
        setState(() => _vaultMessage = restore
            ? (n == 0 ? tr('В папке нет ничего нового') : tr('Восстановлено сообщений: {n}', {'n': n}))
            : (n == 0 ? tr('Всё уже сохранено') : tr('Сохранено сообщений: {n}', {'n': n})));
      }
    } catch (e) {
      if (mounted) setState(() => _vaultMessage = tr('Нужен доступ ко всем файлам: включите его для Nexus в настройках телефона'));
    } finally {
      if (mounted) setState(() => _vaultBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ChatBackupService.mode(db);
    final last = ChatBackupService.lastRun(db);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Сохранение переписок'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height),
        children: [
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(tr('Копия в мою базу')),
            subtitle: Text(_backupMessage ??
                (mode == ChatBackupMode.off
                    ? tr('Выключено')
                    : tr('Не скопировано: {n}. Последний раз: {t}', {
                        'n': ChatBackupService.pending(db),
                        't': last == null ? tr('ещё не копировали') : DateFormat('dd.MM.yy HH:mm').format(last),
                      }))),
            trailing: DropdownButton<ChatBackupMode>(
              value: mode,
              underline: const SizedBox.shrink(),
              onChanged: (m) {
                if (m == null) return;
                ChatBackupService.setMode(db, m);
                setState(() => _backupMessage = null);
                if (m != ChatBackupMode.off) _backupNow();
              },
              items: [
                DropdownMenuItem(value: ChatBackupMode.off, child: Text(tr('Выкл'))),
                DropdownMenuItem(value: ChatBackupMode.live, child: Text(tr('Постоянно'))),
                DropdownMenuItem(value: ChatBackupMode.daily, child: Text(tr('Раз в день'))),
                DropdownMenuItem(value: ChatBackupMode.weekly, child: Text(tr('Раз в неделю'))),
              ],
            ),
          ),
          if (mode != ChatBackupMode.off) ...[
            SwitchListTile(
              secondary: const Icon(Icons.attach_file),
              title: Text(tr('Фото и файлы')),
              subtitle: Text(tr('Каждый до 20 МБ; в бесплатной базе на файлы всего 1 ГБ')),
              value: ChatBackupService.withFiles(db),
              onChanged: (v) {
                ChatBackupService.setWithFiles(db, v);
                setState(() {});
              },
            ),
            ListTile(
              leading: _backupBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_outlined),
              title: Text(tr('Сохранить сейчас')),
              onTap: _backupBusy ? null : _backupNow,
            ),
          ],
          const Divider(height: 24),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_outlined),
            title: Text(tr('Копия на Google Диск')),
            subtitle: Text(_driveMessage ??
                (!GDriveService.configured(db)
                    ? tr('Сначала подключите Google Диск: включите модуль «Google Диск» и откройте его')
                    : tr('Папка Nexus/Chats на вашем Диске, частота — как у копии в базу, вложения до 20 МБ'))),
            value: ChatDriveBackup.isOn(db),
            onChanged: !GDriveService.configured(db)
                ? null
                : (v) {
                    ChatDriveBackup.setOn(db, v);
                    setState(() => _driveMessage = null);
                    if (v) _driveRun(restore: false);
                  },
          ),
          if (ChatDriveBackup.isOn(db)) ...[
            ListTile(
              leading: _driveBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_outlined),
              title: Text(tr('Отправить на Диск сейчас')),
              subtitle: Text(tr('Не отправлено: {n}', {'n': ChatDriveBackup.pending(db)})),
              onTap: _driveBusy ? null : () => _driveRun(restore: false),
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: Text(tr('Восстановить с Google Диска')),
              onTap: _driveBusy ? null : () => _driveRun(restore: true),
            ),
          ],
          if (ChatVault.supported) ...[
            const Divider(height: 24),
            SwitchListTile(
              secondary: const Icon(Icons.folder_special_outlined),
              title: Text(tr('Папка Nexus на телефоне')),
              subtitle: Text(_vaultMessage ??
                  tr('Фото, файлы и история чатов копируются в папку Nexus/Chats в памяти телефона. Удаление приложения её не трогает')),
              value: ChatVault.isOn(db),
              onChanged: (v) async {
                ChatVault.setOn(db, v);
                setState(() => _vaultMessage = null);
                if (v) await _vaultRun(restore: false);
              },
            ),
            ListTile(
              leading: _vaultBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.restore_outlined),
              title: Text(tr('Восстановить из папки Nexus')),
              subtitle: Text(tr('После переустановки: вернуть переписки и вложения')),
              onTap: _vaultBusy ? null : () => _vaultRun(restore: true),
            ),
          ],
        ],
      ),
    );
  }
}
