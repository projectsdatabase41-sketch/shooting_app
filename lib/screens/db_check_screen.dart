import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/db_setup_check.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_loader.dart';
import '../widgets/glass_pill.dart';

/// «Проверка базы»: что из нужного приложению уже создано в вашей базе Supabase,
/// а чего ещё нет. Если чего-то нет — скопируйте SQL, запустите в SQL Editor
/// (повторный запуск безопасен) и проверьте снова.
class DbCheckScreen extends StatefulWidget {
  const DbCheckScreen({super.key});

  @override
  State<DbCheckScreen> createState() => _DbCheckScreenState();
}

class _DbCheckScreenState extends State<DbCheckScreen> {
  late final SupabaseAuthService _auth = SupabaseAuthService(context.read<AppDataStore>().db);
  Map<String, bool>? _tables;
  Map<String, bool>? _functions;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_auth.hasBase) _check();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await DbSetupCheck.run(_auth);
      if (!mounted) return;
      setState(() {
        _tables = r.tables;
        _functions = r.functions;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copySql() async {
    final msg = ScaffoldMessenger.of(context);
    try {
      final sql = await rootBundle.loadString('lib/db/nexus_personal_db.sql');
      await Clipboard.setData(ClipboardData(text: sql));
      msg.showSnackBar(SnackBar(content: Text(tr('SQL скопирован — вставьте в SQL Editor и нажмите Run'))));
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(tr('Не удалось скопировать: {e}', {'e': friendlyError(e)}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editor = DbSetupCheck.sqlEditorUri(_auth.url);
    final missing = [
      ...?_tables?.entries.where((e) => !e.value).map((e) => e.key),
      ...?_functions?.entries.where((e) => !e.value).map((e) => '${e.key}()'),
    ];
    Widget group(String title, Map<String, bool> items) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(title, style: theme.textTheme.titleSmall)),
          for (final e in items.entries)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(e.value ? Icons.check_circle : Icons.cancel_outlined, color: e.value ? Colors.green : theme.colorScheme.error, size: 20),
              title: Text(e.key),
            ),
        ]);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Проверка базы'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: !_auth.hasBase
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr('Сначала укажите адрес и ключ своей базы: Настройки → Данные и синхронизация → Учётная запись.'), textAlign: TextAlign.center)))
          : ListView(
              padding: EdgeInsets.fromLTRB(0, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 0, 24),
              children: [
                if (_busy) const SizedBox(height: 120, child: AppLoader()),
                if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
                if (_tables != null && _functions != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Card(
                      color: missing.isEmpty ? Colors.green.withValues(alpha: 0.15) : theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          missing.isEmpty
                              ? tr('Всё на месте: база готова к работе.')
                              : tr('Не хватает: {n}. Скопируйте SQL, запустите его в SQL Editor и проверьте снова (повторный запуск безопасен).', {'n': missing.length}),
                        ),
                      ),
                    ),
                  ),
                  group(tr('Таблицы'), _tables!),
                  group(tr('Функции'), _functions!),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(onPressed: _busy ? null : _check, icon: const Icon(Icons.refresh), label: Text(tr('Проверить снова'))),
                    OutlinedButton.icon(onPressed: _copySql, icon: const Icon(Icons.copy_outlined), label: Text(tr('Скопировать SQL'))),
                    if (editor != null)
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(editor, mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new),
                        label: Text(tr('Открыть SQL Editor')),
                      ),
                  ]),
                ),
              ],
            ),
    );
  }
}
