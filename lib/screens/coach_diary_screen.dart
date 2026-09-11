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
  /// Показывается в шапке — какого спортсмена сейчас смотрим
  /// (мульти-спортсменский режим, экран открывается из
  /// `CoachAthletesScreen`, которая уже вызвала `selectAthlete`).
  final String athleteName;

  const CoachDiaryScreen({super.key, required this.athleteName});

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
      // Проверяем токен ЯВНО, а не по тому, пуст ли список тренировок —
      // отозванный токен и "у спортсмена правда нет тренировок" дают
      // ОДИНАКОВЫЙ пустой ответ от get_shared_packages (решение
      // пользователя, пункт 9: не должно выглядеть так, будто ничего не
      // изменилось).
      final status = await _access.checkTokenStatus();
      if (status == ShareTokenStatus.revoked) {
        _access.forget();
        if (!mounted) return;
        setState(() {
          _exercises = [];
          _sessions = [];
        });
        // build() провалится в _ConnectForm сразу после forget() —
        // сообщение об отзыве иначе никто бы не увидел: показываем
        // его снэкбаром ДО того, как экран переключится.
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Доступ отозван спортсменом — токен больше не действует. '
            'Подключение снято, локальных данных о нём не осталось.',
          ),
          duration: Duration(seconds: 6),
        ));
        return;
      }

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

  /// `_exercises` — снимки-упражнения (реальная таблица `exercises`),
  /// связаны с тренировкой по `package_id`, а не по `id`: отдельного
  /// `exercise_id` на самой тренировке в реальной схеме нет.
  String _exerciseName(String packageId) => _exercises
      .firstWhere((e) => e['package_id'] == packageId, orElse: () => const {'exercise_name': 'Упражнение'})['exercise_name'] as String? ?? 'Упражнение';

  @override
  Widget build(BuildContext context) {
    // Подключение делает CoachAthletesScreen ДО перехода сюда
    // (selectAthlete) — сюда нельзя попасть без него, кроме случая,
    // когда токен отозвали прямо во время просмотра (см. _load).
    if (!_access.hasConnection) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.athleteName)),
        body: const EmptyState(
          icon: Icons.link_off,
          text: 'Подключение снято — вернитесь к списку спортсменов.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.athleteName),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
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
                    final packageId = s['id'] as String;
                    final started = DateTime.tryParse('${s['started_at']}');
                    return ListTile(
                      title: Text(_exerciseName(packageId)),
                      subtitle: Text(
                        started == null ? '—' : DateFormat('dd.MM.yyyy HH:mm').format(started.toLocal()),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _SharedSessionScreen(
                          access: _access,
                          sessionId: packageId,
                          title: _exerciseName(packageId),
                        ),
                      )),
                    );
                  },
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
      shots.sort((a, b) => (a['shot_no'] as num).compareTo(b['shot_no'] as num));
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
                          '№${s['shot_no']} · ${(s['final_score'] as num).toStringAsFixed(1)}'
                          '  X:${(s['x_mm'] as num? ?? 0).toStringAsFixed(1)} Y:${(s['y_mm'] as num? ?? 0).toStringAsFixed(1)}',
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
