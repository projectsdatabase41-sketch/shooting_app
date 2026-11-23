import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import 'dart:async' show unawaited;
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

  /// Диалог прогресса «N из M» с кнопкой «Отмена» (отзыв 22.11: импорт/выкладка
  /// большой истории шли молча, и приложение выглядело зависшим). Возвращает
  /// функцию закрытия диалога.
  void Function() _showProgress({
    required String title,
    required ValueNotifier<(int, int)> progress,
    required String Function(int done, int total) progressText,
    required bool Function() cancelled,
    required VoidCallback onCancel,
    required String note,
  }) {
    BuildContext? dialog;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialog = ctx;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: Text(title),
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, v, __) {
                final done = v.$1, total = v.$2;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  // clamp: во время прохода могут прийти новые сообщения и «всего»
                  // станет меньше уже сделанного — полоска не должна упасть.
                  LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
                  const SizedBox(height: 12),
                  Text(total > 0 ? progressText(done, total) : tr('Читаю данные…')),
                  const SizedBox(height: 6),
                  Text(note, style: Theme.of(ctx).textTheme.bodySmall),
                ]);
              },
            ),
            actions: [
              TextButton(
                onPressed: cancelled()
                    ? null
                    : () {
                        onCancel();
                        setD(() {});
                      },
                child: Text(cancelled() ? tr('Останавливаю…') : tr('Отмена')),
              ),
            ],
          ),
        );
      },
    ));
    return () {
      final d = dialog;
      if (d != null && d.mounted) {
        Navigator.of(d).pop();
        return;
      }
      // Диалог ещё не успел построиться — закроем его сразу после кадра.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = dialog;
        if (c != null && c.mounted) Navigator.of(c).pop();
      });
    };
  }

  /// Восстановление с Диска: импорт тысяч сообщений нельзя делать «молча» —
  /// показываем «восстановлено N из M» и даём отменить (отзыв 22.11: после
  /// восстановления переписки приложение попадало в «приложение не отвечает»).
  Future<void> _driveRun({required bool restore}) async {
    if (restore) {
      final was = ChatDriveBackup.restoredAt(db);
      if (was != null) {
        final again = await showGlassDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Восстановить ещё раз?')),
            content: Text(tr(
                'Переписка с Google Диска уже восстанавливалась {t}. Повторный импорт — только по этой кнопке: он долгий и на большой истории может подтормозить телефон.',
                {'t': DateFormat('dd.MM.yy HH:mm').format(was)})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Восстановить'))),
            ],
          ),
        );
        if (again != true) return;
      }
    }
    if (!mounted) return;
    setState(() {
      _driveBusy = true;
      _driveMessage = null;
    });
    final progress = ValueNotifier<(int, int)>((0, 0));
    var cancelled = false;
    final closeDialog = restore
        ? _showProgress(
            title: tr('Восстановление с Google Диска'),
            progress: progress,
            progressText: (done, total) => tr('Восстановлено {n} из {m}', {'n': done, 'm': total}),
            cancelled: () => cancelled,
            onCancel: () => cancelled = true,
            note: tr('Уже добавленные сообщения останутся, даже если отменить или прервётся связь'),
          )
        : () {};
    try {
      final b = ChatDriveBackup(db, GDriveService(db));
      final n = restore
          ? await b.restore(
              ChatMessagesRepository(db),
              force: true, // повторно — только по этой кнопке (флаг в настройках)
              onProgress: (done, total) => progress.value = (done, total),
              cancelled: () => cancelled,
            )
          : await b.sync();
      if (mounted) {
        setState(() => _driveMessage = restore
            ? (cancelled
                ? tr('Восстановление остановлено: добавлено сообщений {n}', {'n': n})
                : (n == 0 ? tr('Восстановить с Диска нечего: всё уже на месте') : tr('Восстановлено сообщений: {n}', {'n': n})))
            : (n == 0 ? tr('Всё уже на Диске') : tr('Отправлено на Диск: {n}', {'n': n})));
      }
    } catch (e) {
      if (mounted) setState(() => _driveMessage = tr('Не удалось до конца: {e}. Добавленные сообщения сохранены', {'e': friendlyError(e)}));
    } finally {
      closeDialog();
      progress.dispose();
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  /// Пароль папки: если хранилище уже есть на телефоне (после переустановки) — вводится прежний,
  /// иначе придумывается новый. `false` — отказались или ввели неверный.
  Future<bool> _ensureVaultPassword() async {
    if (await ChatVault.hasKey()) return true;
    final existing = await ChatVault.hasVaultFile();
    if (!mounted) return false;
    final a = TextEditingController(), b = TextEditingController();
    String? error;
    bool busy = false;
    final ok = await showGlassDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing ? tr('Пароль папки Nexus') : tr('Придумайте пароль папки')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(existing
                ? tr('Введите пароль, которым папка была защищена раньше.')
                : tr('Файлы и история чатов в папке будут зашифрованы этим паролем. Забытый пароль восстановить нельзя: без него данные не откроет никто, в том числе вы.')),
            const SizedBox(height: 8),
            TextField(controller: a, obscureText: true, autofocus: true, decoration: InputDecoration(labelText: tr('Пароль (от 8 символов)'))),
            if (!existing) TextField(controller: b, obscureText: true, decoration: InputDecoration(labelText: tr('Повторите пароль'))),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (a.text.length < 8) {
                        setS(() => error = tr('Не короче 8 символов'));
                        return;
                      }
                      if (!existing && a.text != b.text) {
                        setS(() => error = tr('Пароли не совпадают'));
                        return;
                      }
                      setS(() {
                        busy = true;
                        error = null;
                      });
                      bool good;
                      try {
                        good = await ChatVault.setPassword(a.text);
                      } catch (_) {
                        good = false;
                        error = tr('Нужен доступ ко всем файлам: включите его для Nexus в настройках телефона');
                      }
                      if (!ctx.mounted) return;
                      if (good) {
                        Navigator.pop(ctx, true);
                      } else {
                        setS(() {
                          busy = false;
                          error ??= tr('Неверный пароль');
                        });
                      }
                    },
              child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(tr('ОК')),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  /// Сохранение/восстановление папки Nexus. Большая история шифруется и
  /// расшифровывается на телефоне: показываем «N из M» и даём отменить (отзыв
  /// 22.11 — после включения защищённой папки мессенджер переставал отвечать).
  Future<void> _vaultRun({required bool restore}) async {
    setState(() {
      _vaultBusy = true;
      _vaultMessage = null;
    });
    final progress = ValueNotifier<(int, int)>((0, 0));
    var cancelled = false;
    void Function() closeDialog = () {};
    try {
      if (!await _ensureVaultPassword()) {
        if (mounted) setState(() => _vaultMessage = null);
        return;
      }
      if (!mounted) return;
      closeDialog = _showProgress(
        title: restore ? tr('Восстановление из папки Nexus') : tr('Сохранение в папку Nexus'),
        progress: progress,
        progressText: restore
            ? (done, total) => tr('Восстановлено {n} из {m}', {'n': done, 'm': total})
            : (done, total) => tr('Сохранено {n} из {m}', {'n': done, 'm': total}),
        cancelled: () => cancelled,
        onCancel: () => cancelled = true,
        note: tr('Уже добавленные сообщения останутся, даже если отменить или прервётся связь'),
      );
      final repo = ChatMessagesRepository(db);
      void onStep(int done, int total) => progress.value = (done, total);
      // Прежняя открытая копия, если была, заменяется зашифрованной.
      await ChatVault.migrateLegacy(db, repo, onProgress: onStep, cancelled: () => cancelled);
      final n = restore
          ? await ChatVault.restore(db, repo, onProgress: onStep, cancelled: () => cancelled)
          : await ChatVault.sync(db, onProgress: onStep, cancelled: () => cancelled);
      if (mounted) {
        setState(() => _vaultMessage = restore
            ? (cancelled
                ? tr('Восстановление остановлено: добавлено сообщений {n}', {'n': n})
                : (n == 0 ? tr('В папке нет ничего нового') : tr('Восстановлено сообщений: {n}', {'n': n})))
            : (cancelled
                ? tr('Сохранение остановлено: записано сообщений {n}', {'n': n})
                : (n == 0 ? tr('Всё уже сохранено') : tr('Сохранено сообщений: {n}', {'n': n}))));
      }
    } catch (e) {
      final s = '$e';
      if (mounted) {
        setState(() => _vaultMessage = s.contains('доступа')
            ? tr('Нужен доступ ко всем файлам: включите его для Nexus в настройках телефона')
            : tr('Не удалось: {e}', {'e': friendlyError(e)}));
      }
    } finally {
      closeDialog();
      progress.dispose();
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
      body: AppBackdrop(kind: 'settings', child: ListView(
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
              subtitle: Text(ChatDriveBackup.restoredAt(db) != null
                  ? tr('Уже восстанавливали {t}. Повторно — только по этой кнопке',
                      {'t': DateFormat('dd.MM.yy HH:mm').format(ChatDriveBackup.restoredAt(db)!)})
                  : tr('Вернуть переписку и вложения из папки Nexus/Chats на Диске')),
              onTap: _driveBusy ? null : () => _driveRun(restore: true),
            ),
          ],
          if (ChatVault.supported) ...[
            const Divider(height: 24),
            SwitchListTile(
              secondary: const Icon(Icons.folder_special_outlined),
              title: Text(tr('Папка Nexus на телефоне')),
              subtitle: Text(_vaultMessage ??
                  tr('Фото, файлы и история чатов копируются в папку Nexus/Chats зашифрованными вашим паролем. Удаление приложения её не трогает')),
              value: ChatVault.isOn(db),
              onChanged: (v) async {
                setState(() => _vaultMessage = null);
                if (!v) {
                  ChatVault.setOn(db, false);
                  setState(() {});
                  return;
                }
                if (!await _ensureVaultPassword()) return;
                ChatVault.setOn(db, true);
                await _vaultRun(restore: false);
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
      )),
    );
  }
}
