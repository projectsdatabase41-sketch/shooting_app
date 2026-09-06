import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';

/// Экран тренера — "дневник" (раздел 8 ТЗ): список тренировок
/// подключённого спортсмена по токену, тап → выстрелы этой тренировки
/// и общий чат с ней.
///
/// Тренер подключается к ЧУЖОЙ базе (см. `CoachAccessService`) — своей
/// регистрации в ней нет и не нужно, RPC на стороне спортсмена сами
/// проверяют токен. Данные не кэшируются локально: список всегда живой,
/// "Обновить" перечитывает его заново.
class CoachDiaryScreen extends StatefulWidget {
  const CoachDiaryScreen({super.key});

  @override
  State<CoachDiaryScreen> createState() => _CoachDiaryScreenState();
}

class _CoachDiaryScreenState extends State<CoachDiaryScreen> {
  late final CoachAccessService _access;
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _exercises = [];
  List<Map<String, dynamic>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _access = CoachAccessService(context.read<AppDataStore>().db);
    if (_access.hasConnection) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final exercises = await _access.fetchExercises();
      final sessions = await _access.fetchSessions();
      sessions.sort((a, b) => '${b['started_at']}'.compareTo('${a['started_at']}'));
      if (!mounted) return;
      setState(() {
        _exercises = exercises;
        _sessions = sessions;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _exerciseName(String? id) => _exercises
      .firstWhere((e) => e['id'] == id, orElse: () => const {'name': 'Упражнение'})['name'] as String;

  void _disconnect() {
    _access.forget();
    setState(() {
      _sessions = [];
      _exercises = [];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_access.hasConnection) {
      return _ConnectForm(access: _access, onConnected: () {
        setState(() {});
        _load();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Дневник'),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: 'Отключиться',
            onPressed: _disconnect,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _sessions.isEmpty && !_loading
              ? const EmptyState(
                  icon: Icons.groups_outlined,
                  text: 'У спортсмена пока нет отправленных тренировок',
                )
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, i) {
                    final s = _sessions[i];
                    final started = DateTime.tryParse('${s['started_at']}');
                    return ListTile(
                      title: Text(_exerciseName(s['exercise_id'] as String?)),
                      subtitle: Text(
                        started == null ? '—' : DateFormat('dd.MM.yyyy HH:mm').format(started.toLocal()),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _SharedSessionScreen(
                          access: _access,
                          sessionId: s['id'] as String,
                          title: _exerciseName(s['exercise_id'] as String?),
                        ),
                      )),
                    );
                  },
                ),
    );
  }
}

/// Форма подключения к базе спортсмена: адрес, публичный ключ, токен —
/// три значения, которые спортсмен передаёт тренеру сам (токен — один
/// раз, из своих настроек; адрес и ключ его проекта не секретны).
class _ConnectForm extends StatefulWidget {
  final CoachAccessService access;
  final VoidCallback onConnected;

  const _ConnectForm({required this.access, required this.onConnected});

  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.access.setConnection(url: _url.text, anonKey: _key.text, token: _token.text);
    try {
      // Проверяем сразу же — реальным запросом, а не просто сохраняем
      // поля: неверный токен или адрес должны стать ясны здесь, а не
      // молчаливым пустым списком на следующем экране.
      await widget.access.fetchSessions();
      widget.onConnected();
    } catch (e) {
      widget.access.forget();
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Дневник')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Подключитесь к базе спортсмена: адрес и публичный ключ его '
            'проекта Supabase (не секретны, спортсмен присылает сам) и '
            'токен доступа — тот выдаётся один раз в его настройках.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Адрес базы спортсмена',
              hintText: 'https://xxxx.supabase.co',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _key,
            decoration: const InputDecoration(labelText: 'Публичный ключ (anon / publishable)'),
            autocorrect: false,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _token,
            decoration: const InputDecoration(labelText: 'Токен доступа'),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Подключиться'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Одна тренировка спортсмена, только чтение: список выстрелов и общий
/// чат с ним (тот же уровень 'coach', что и "Тренер" на его рабочем
/// столе — ответ отсюда попадёт именно туда после его следующей
/// синхронизации).
class _SharedSessionScreen extends StatefulWidget {
  final CoachAccessService access;
  final String sessionId;
  final String title;

  const _SharedSessionScreen({required this.access, required this.sessionId, required this.title});

  @override
  State<_SharedSessionScreen> createState() => _SharedSessionScreenState();
}

class _SharedSessionScreenState extends State<_SharedSessionScreen> {
  final _input = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  String? _error;
  List<Map<String, dynamic>> _shots = [];
  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shots = await widget.access.fetchShots(widget.sessionId);
      final comments = await widget.access.fetchComments(widget.sessionId);
      shots.sort((a, b) => (a['shot_number'] as num).compareTo(b['shot_number'] as num));
      final coachThread = comments.where((c) => c['level'] == 'coach').toList()
        ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
      if (!mounted) return;
      setState(() {
        _shots = shots;
        _comments = coachThread;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.access.addComment(sessionId: widget.sessionId, level: 'coach', text: text);
      _input.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM HH:mm');
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Text('Выстрелы', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      for (final s in _shots)
                        Text(
                          '№${s['shot_number']} · ${(s['score'] as num).toStringAsFixed(1)}'
                          '  X:${(s['x_mm'] as num).toStringAsFixed(1)} Y:${(s['y_mm'] as num).toStringAsFixed(1)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 20),
                      Text('Чат', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      for (final c in _comments)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${c['author_role'] == 'coach' ? 'Тренер' : 'Спортсмен'}: '
                                '${df.format(DateTime.parse('${c['created_at']}').toLocal())}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              Text('${c['text']}'),
                            ],
                          ),
                        ),
                      if (_comments.isEmpty) const Text('Переписки пока нет'),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          decoration: const InputDecoration(hintText: 'Написать спортсмену…'),
                        ),
                      ),
                      IconButton(
                        icon: _sending
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        onPressed: _sending ? null : _send,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
