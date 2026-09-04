import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_data_store.dart';
import 'home_shell.dart';

/// Экран подключения к базе (раздел 1 ТЗ). Пока работает на тестовых
/// данных — реальное подключение к Supabase осознанно вне объёма
/// текущего ТЗ (раздел 12 п.1).
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _dbName = TextEditingController();
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isAthlete = true;
  bool _isCoach = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            // Экран входа — единственный без нижней навигации, поэтому
            // ограничиваем ширину: на Windows во весь экран поля ввода
            // растягивались на полтора метра и выглядели сломанными.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(Icons.gps_fixed, size: 32, color: cs.onPrimaryContainer),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Подключение к базе', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Свои результаты — в своей базе Supabase',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(controller: _dbName, decoration: const InputDecoration(labelText: 'Имя базы')),
                  const SizedBox(height: 10),
                  TextField(controller: _url, decoration: const InputDecoration(labelText: 'URL Supabase')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _apiKey,
                    decoration: const InputDecoration(labelText: 'API-ключ'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: 'Пароль'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 20),
                  Text('Роль', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Я спортсмен'),
                    value: _isAthlete,
                    onChanged: (v) => setState(() => _isAthlete = v ?? true),
                  ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Я тренер'),
                    value: _isCoach,
                    onChanged: (v) => setState(() => _isCoach = v ?? false),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    color: cs.surfaceContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Пока приложение работает на локальных тестовых данных — '
                              'реального подключения к облаку ещё нет (следующий этап).',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => _connect(context),
                    child: const Text('Подключить'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () => _connect(context),
                    child: const Text('Регистрация'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _connect(BuildContext context) {
    if (!_isAthlete && !_isCoach) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите хотя бы одну роль')),
      );
      return;
    }
    final store = context.read<AppDataStore>();
    store.isAthlete = _isAthlete;
    store.isCoach = _isCoach;
    store.saveSettings();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeShell()),
    );
  }
}
