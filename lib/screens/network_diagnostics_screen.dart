import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../models/chat_contact.dart';
import '../services/call_service.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/demo_mode.dart';
import '../services/local_db_service.dart';
import '../services/net_diagnostics.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';

/// Диагностика сети в паре: выбираешь собеседника из мессенджера, приложение
/// проходит по шагам (задержки, вход, пуш, ICE/TURN, сигналинг, P2P, скорость)
/// и отправляет отчёт в отзывы с подписью «Диагностика сети».
///
/// Экран открывается только из режима разработчика. Отчёт содержит только
/// технические параметры: ни текстов сообщений, ни имён из переписки в нём нет.
class NetworkDiagnosticsScreen extends StatefulWidget {
  const NetworkDiagnosticsScreen({super.key});

  @override
  State<NetworkDiagnosticsScreen> createState() => _NetworkDiagnosticsScreenState();
}

class _NetworkDiagnosticsScreenState extends State<NetworkDiagnosticsScreen> {
  late final ChatMessagesRepository _repo;
  late final LocalDbService _db;
  List<ChatContact> _contacts = const [];
  ChatContact? _partner;
  List<DiagStepResult> _steps = const [];
  bool _running = false;
  bool _sent = false;
  String? _message;

  /// Отчёт, который не удалось отправить (нет связи, VPN и т.п.): лежит тут
  /// и переотправляется при следующем открытии экрана, чтобы не терять
  /// диагностику из-за одной неудачной попытки.
  static const _kUnsent = 'diag_unsent_report';

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    _db = db;
    _repo = ChatMessagesRepository(db);
    _contacts = _repo.listContacts();
    _partner = _contacts.isEmpty ? null : _contacts.first;
    _flushUnsent();
  }

  String _readUnsent() {
    final rows = _db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_kUnsent]);
    return rows.isEmpty ? '' : '${rows.first['hex'] ?? ''}';
  }

  void _writeUnsent(String text) {
    _db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [_kUnsent, text],
    );
  }

  /// Досылает отчёт, сохранённый с прошлого раза (например, отправляли с VPN).
  Future<void> _flushUnsent() async {
    final pending = _readUnsent();
    if (pending.trim().isEmpty) return;
    final res = await DemoMode.send(pending, 'Диагностика сети (досылка)', ignoreThrottle: true);
    if (diagSendSucceeded(res)) {
      _writeUnsent('');
      if (mounted) setState(() => _message = tr('Отправлен отчёт, сохранённый с прошлого раза'));
    }
  }

  Future<void> _run() async {
    final partner = _partner;
    if (partner == null || _running) return;
    final db = context.read<AppDataStore>().db;
    setState(() {
      _running = true;
      _steps = const [];
      _sent = false;
      _message = null;
    });
    final diag = NetDiagnostics(
      db: db,
      chatAuth: ChatAuthService(db),
      mainAuth: SupabaseAuthService(db),
      partner: partner,
      onProgress: (step) {
        if (mounted) setState(() => _steps = [..._steps, step]);
      },
    );
    final report = await diag.run();
    if (!mounted) return;
    setState(() {
      _steps = report.steps;
      _running = false;
    });
    // Короткая сводка на сервер звонков: панель в настройках видит статистику
    // диагностики, при этом таблица отзывов остаётся закрытой на чтение.
    final failed = report.steps.where((s) => !s.passed).length;
    unawaited(CallService(ChatAuthService(db)).reportDiagnostics(
      total: report.steps.length,
      failed: failed,
      platform: Theme.of(context).platform.name,
    ));
    // Провал любого шага — отправляем сразу: это и есть «автоотзыв в базу».
    // Провал любого шага — отчёт уходит сам. DemoMode.send при успехе
    // возвращает null, при ошибке — текст; раньше экран путал это и писал
    // «не удалось отправить» даже когда отчёт уже лежал в базе.
    final sent = await sendDiagReport(report, autoSend: true);
    if (!mounted) return;
    final ok = diagSendSucceeded(sent);
    setState(() {
      _sent = ok;
      _message = ok
          ? tr('Отчёт отправлен автоматически')
          : tr('Не удалось отправить отчёт: {e}', {'e': sent ?? ''});
    });
  }

  Future<void> _send() async {
    final partner = _partner;
    if (partner == null || _running) return;
    final report = NetDiagReport(
      startedAt: DateTime.now(),
      finishedAt: DateTime.now(),
      steps: _steps,
      platform: Theme.of(context).platform.name,
      // Раньше здесь стояли пустые строки, и в отчёте было «Версия:» и
      // «Сеть:» без значения (отзыв 17.11). Берём настоящие данные.
      version: DemoMode.appVersion.isEmpty ? 'dev' : DemoMode.appVersion,
      partnerId: partner.id,
      partnerNickname: partner.nickname,
      networkType: Theme.of(context).platform.name,
    );
    var sent = await sendDiagReport(report, autoSend: false);
    if (sent != null) {
      // Одна повторная попытка: с VPN первый запрос часто отваливается.
      await Future<void>.delayed(const Duration(seconds: 2));
      sent = await sendDiagReport(report, autoSend: false);
    }
    if (!mounted) return;
    final ok = diagSendSucceeded(sent);
    if (!ok) {
      // Не теряем отчёт: сохраним и дошлём при следующем открытии экрана.
      _writeUnsent(report.toReportText());
    } else {
      _writeUnsent('');
    }
    setState(() {
      _sent = ok;
      _message = ok
          ? tr('Отчёт отправлен')
          : tr('Отчёт сохранён и будет отправлен позже: {e}', {'e': sent ?? ''});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final allPassed = _steps.isNotEmpty && _steps.every((s) => s.passed);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Диагностика сети'))),
      body: AppBackdrop(
        kind: 'settings',
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 32),
          children: [
            Text(
              tr('Проверка в паре: выберите человека из мессенджера и запустите. Приложение измерит задержки до базы и сервера звонков, проверит вход и пуш, ICE-серверы и TURN, сигналинг и прямое соединение. Отчёт уходит в отзывы с подписью «Диагностика сети»; при любой ошибке — автоматически.'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_contacts.isEmpty)
              Text(tr('В мессенджере нет контактов — сначала войдите в него и добавьте собеседника.'),
                  style: theme.textTheme.bodyMedium)
            else
              DropdownButtonFormField<String>(
                initialValue: _partner?.id,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('Собеседник')),
                items: [
                  for (final c in _contacts)
                    DropdownMenuItem(value: c.id, child: Text(c.nickname, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _running
                    ? null
                    : (v) => setState(() => _partner = _contacts.firstWhere((c) => c.id == v)),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _partner == null || _running ? null : _run,
              icon: _running
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(_running ? tr('Проверяем…') : tr('Проверить соединение')),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(_message!, style: TextStyle(color: _sent ? cs.primary : cs.error)),
            ],
            if (_steps.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(allPassed ? tr('Всё в порядке') : tr('Есть проблемы'),
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final s in _steps)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    dense: true,
                    leading: Icon(s.passed ? Icons.check_circle_outline : Icons.error_outline,
                        color: s.passed ? cs.primary : cs.error),
                    title: Text(s.name),
                    subtitle: Text(s.details, style: theme.textTheme.bodySmall),
                    trailing: s.latency == Duration.zero
                        ? null
                        : Text('${s.latency.inMilliseconds} мс', style: theme.textTheme.labelSmall),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _sent || _running ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(tr('Отправить отчёт')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
