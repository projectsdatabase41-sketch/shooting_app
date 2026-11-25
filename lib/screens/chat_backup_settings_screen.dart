import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../gdrive/chat_ai_export.dart';
import '../gdrive/chat_drive_backup.dart';
import '../gdrive/gdrive_service.dart';
import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/chat_messages_repository.dart';
import '../services/local_db_service.dart';
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
  bool _driveBusy = false;
  String? _driveMessage;
  bool _aiBusy = false;
  String? _aiMessage;

  LocalDbService get db => widget.db;

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
  Future<void> _exportNow() async {
    if (!GDriveService.configured(db)) {
      setState(() => _aiMessage = tr('Сначала подключите Google Диск: включите модуль «Google Диск» и откройте его'));
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiMessage = null;
    });
    final progress = ValueNotifier<(int, int)>((0, 0));
    var cancelled = false;
    final closeDialog = _showProgress(
      title: tr('Выгрузка на Google Диск'),
      progress: progress,
      progressText: (done, total) => tr('Переписок выгружено: {n} из {m}', {'n': done, 'm': total}),
      cancelled: () => cancelled,
      onCancel: () => cancelled = true,
      note: tr('История и медиа кладутся в Nexus/Chats на вашем Диске; вложения могут идти долго'),
    );
    try {
      final r = await ChatAiExport(db, GDriveService(db))
          .exportAll(cancelled: () => cancelled, onProgress: (done, total) => progress.value = (done, total));
      final msg = r.messageText();
      if (mounted) {
        setState(() => _aiMessage = cancelled ? '${tr('Выгрузка остановлена')}. $msg' : msg);
        if (r.errors.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('Не всё выгружено: {e}', {'e': r.errors.first}))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        final msg = friendlyError(e);
        setState(() => _aiMessage = tr('Не удалось выгрузить: {e}', {'e': msg}));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      closeDialog();
      progress.dispose();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// Статус последней выгрузки «для ИИ» — под кнопкой «Выгрузить сейчас».
  String _aiStatusText() {
    final last = ChatAiExport.lastRun(db);
    if (last == null) return tr('Ещё не выгружали: формат для ИИ — messages.jsonl, chat.md, media/');
    final st = ChatAiExport.lastStatus(db);
    final when = tr('Последняя выгрузка: {t}', {'t': DateFormat('dd.MM.yy HH:mm').format(last)});
    if (st == null || st == 'ok') return when;
    return '$when. ${tr('В прошлый раз были ошибки')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Сохранение переписок'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: AppBackdrop(kind: 'settings', child: ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height),
        children: [
          // Отзывы 25.11 (73e72e2e, 75a2fd00, 9a52a30d): «копия в мою базу не
          // нужна», «этот бэкап только для Google Диска, всё остальное
          // лишнее» — оставлен один способ хранения, Диск.
          SwitchListTile(
            secondary: const Icon(Icons.cloud_outlined),
            title: Text(tr('Копия на Google Диск')),
            subtitle: Text(_driveMessage ??
                (!GDriveService.configured(db)
                    ? tr('Сначала подключите Google Диск: включите модуль «Google Диск» и откройте его')
                    : tr('Папка Nexus/Chats на вашем Диске: история, фото и файлы до 20 МБ'))),
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
          if (GDriveService.configured(db)) ...[
            const Divider(height: 24),
            SwitchListTile(
              secondary: const Icon(Icons.smart_toy_outlined),
              title: Text(tr('Хранить переписки только на Google Диске')),
              subtitle: Text(tr(
                  'История и медиа на Диске, в облаке только доставка: старые сообщения удаляются из Supabase после выгрузки')),
              value: ChatDriveBackup.driveOnlyOn(db),
              onChanged: (v) {
                ChatDriveBackup.setDriveOnly(db, v);
                setState(() => _aiMessage = null);
              },
            ),
            ListTile(
              leading: _aiBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file_outlined),
              title: Text(tr('Выгрузить сейчас')),
              subtitle: Text(_aiMessage ?? _aiStatusText()),
              onTap: _aiBusy ? null : _exportNow,
            ),
          ],
        ],
      )),
    );
  }
}
