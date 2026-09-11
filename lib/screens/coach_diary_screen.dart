import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import 'coach_exercise_detail_screen.dart';

/// Экран тренера — список УПРАЖНЕНИЙ подключённого спортсмена (раздел 8
/// ТЗ), как папка с файлами: сначала выбираешь упражнение (сгруппировано
/// по названию, самое недавно тренированное — первым, с датой последней
/// тренировки), потом — конкретную дату тренировки внутри него, потом
/// открывается подробный просмотр (`CoachExerciseDetailScreen`).
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

  /// Группировка тренировок по названию упражнения — сессии внутри
  /// каждой группы уже отсортированы по дате (новые сначала, см. `_load`),
  /// а сами группы отсортированы по дате ПОСЛЕДНЕЙ тренировки: то
  /// упражнение, которым занимались недавнее всех, — первое в списке
  /// (решение пользователя).
  List<_ExerciseGroup> get _groups {
    final byName = <String, List<Map<String, dynamic>>>{};
    for (final s in _sessions) {
      final name = _exerciseName(s['id'] as String);
      (byName[name] ??= []).add(s);
    }
    final groups = [for (final e in byName.entries) _ExerciseGroup(name: e.key, sessions: e.value)];
    groups.sort((a, b) => '${b.sessions.first['started_at']}'.compareTo('${a.sessions.first['started_at']}'));
    return groups;
  }

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

    final groups = _groups;
    final df = DateFormat('dd.MM.yyyy');

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
          : groups.isEmpty && !_loading
              ? const EmptyState(
                  icon: Icons.groups_outlined,
                  text: 'У спортсмена пока нет отправленных тренировок',
                )
              : ListView.builder(
                  itemCount: groups.length,
                  itemBuilder: (context, i) {
                    final g = groups[i];
                    final last = DateTime.tryParse('${g.sessions.first['started_at']}');
                    return ListTile(
                      title: Text(g.name),
                      subtitle: Text(
                        // Дата ВСЕГДА видна в строке упражнения — по ней
                        // видно, что тренировали последним (решение
                        // пользователя).
                        'Последняя: ${last == null ? '—' : df.format(last.toLocal())} · '
                        'тренировок: ${g.sessions.length}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _ExerciseTrainingsScreen(
                          access: _access,
                          exercises: _exercises,
                          group: g,
                        ),
                      )),
                    );
                  },
                ),
    );
  }
}

class _ExerciseGroup {
  final String name;
  final List<Map<String, dynamic>> sessions;
  const _ExerciseGroup({required this.name, required this.sessions});
}

/// Список дат тренировок ОДНОГО упражнения — второй уровень (раздел 8
/// ТЗ: "упражнение → тренировка").
class _ExerciseTrainingsScreen extends StatelessWidget {
  final CoachAccessService access;
  final List<Map<String, dynamic>> exercises;
  final _ExerciseGroup group;

  const _ExerciseTrainingsScreen({required this.access, required this.exercises, required this.group});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy · HH:mm');
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      body: ListView.builder(
        itemCount: group.sessions.length,
        itemBuilder: (context, i) {
          final s = group.sessions[i];
          final started = DateTime.tryParse('${s['started_at']}');
          return ListTile(
            title: Text(started == null ? '—' : df.format(started.toLocal())),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CoachExerciseDetailScreen(
                access: access,
                packageRow: s,
                exercises: exercises,
                exerciseName: group.name,
              ),
            )),
          );
        },
      ),
    );
  }
}
