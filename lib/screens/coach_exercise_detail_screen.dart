import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../logic/ai_context.dart';
import '../logic/shot_analytics.dart';
import '../models/exercise.dart';
import '../models/exercise_detail_block.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../painters/target_painter.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../state/app_data_store.dart';
import '../state/exercise_detail_view_model.dart';
import '../state/personalization_view_model.dart';
import '../state/target_view_model.dart';
import '../widgets/analytics_panel.dart';
import '../widgets/empty_state.dart';
import '../widgets/shot_wheel.dart';
import '../widgets/target_canvas.dart';
import 'ai_chat_screen.dart';

/// Просмотр ОДНОЙ тренировки спортсмена тренером — те же перестраиваемые
/// блоки, что и у спортсмена (`ExerciseHistoryDetailScreen`): шапка,
/// мишень со слайдером, серии → выстрелы → заметка к выстрелу,
/// статистика, чат с ИИ. Данные приходят по RPC (`CoachAccessService`),
/// а не из локальной базы — поэтому свой, не общий со спортсменом,
/// экран (заметки к выстрелу читаются из `fetchComments`, а не из
/// локального `CommentsRepository`, и мишень открыта на чтение —
/// `TargetViewModel(isOwnSession: false)`).
class CoachExerciseDetailScreen extends StatefulWidget {
  final CoachAccessService access;
  final Map<String, dynamic> packageRow;
  final List<Map<String, dynamic>> exercises;
  final String exerciseName;

  const CoachExerciseDetailScreen({
    super.key,
    required this.access,
    required this.packageRow,
    required this.exercises,
    required this.exerciseName,
  });

  @override
  State<CoachExerciseDetailScreen> createState() => _CoachExerciseDetailScreenState();
}

class _CoachExerciseDetailScreenState extends State<CoachExerciseDetailScreen> {
  bool _loading = true;
  String? _error;
  TrainingSession? _session;
  Exercise? _exercise;
  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = '${widget.packageRow['id']}';
    try {
      final shots = await widget.access.fetchShots(id);
      final comments = await widget.access.fetchComments(id);
      final session = mapCoachSessions([widget.packageRow], widget.exercises, {id: shots}).firstOrNull;
      if (!mounted) return;
      if (session == null) {
        setState(() {
          _error = 'Не удалось разобрать тренировку';
          _loading = false;
        });
        return;
      }
      setState(() {
        _session = session;
        _exercise = Exercise(
          id: session.id,
          name: widget.exerciseName,
          targetFaceCode: session.targetFaceCode,
          totalShots: session.shots.length,
          seriesSize: 1,
        );
        _comments = comments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final error = _error;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.exerciseName)),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error))),
      );
    }

    final store = context.read<AppDataStore>();
    final session = _session!;
    final exercise = _exercise!;
    final face = TargetFace.byCode(exercise.targetFaceCode);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TargetViewModel>(
          create: (_) => TargetViewModel(
            store: store,
            session: session,
            exercise: exercise,
            face: face,
            isOwnSession: false,
          ),
        ),
        ChangeNotifierProvider<ExerciseDetailViewModel>(
          create: (_) => ExerciseDetailViewModel(store.db),
        ),
      ],
      child: _DetailBody(session: session, exercise: exercise, face: face, comments: _comments),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final TrainingSession session;
  final Exercise exercise;
  final TargetFace face;
  final List<Map<String, dynamic>> comments;

  const _DetailBody({required this.session, required this.exercise, required this.face, required this.comments});

  @override
  Widget build(BuildContext context) {
    final blocks = context.watch<ExerciseDetailViewModel>();
    // Пока на мишени два пальца (щипок для зума), список блоков не
    // должен листаться сам — иначе прокрутка страницы забирает жест
    // раньше, чем TargetCanvas успевает опознать его как зум (решение
    // пользователя). Тот же флаг, что гасит свайп PageView на рабочем
    // столе тренировки (target_screen.dart).
    final multiTouch = context.watch<TargetViewModel>().multiTouch;
    final total = session.totalScore;

    return Scaffold(
      appBar: AppBar(
        title: Text(exercise.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${total.toStringAsFixed(1)} очка (${total.round()})'),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Порядок блоков',
            onPressed: () => _openBlockSettings(context),
          ),
        ],
      ),
      body: ListView(
        physics: multiTouch ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          for (final block in blocks.visible) ...[
            _buildBlock(context, block),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildBlock(BuildContext context, ExerciseDetailBlock block) {
    switch (block) {
      case ExerciseDetailBlock.target:
        return const _TargetBlock();
      case ExerciseDetailBlock.series:
        return _SeriesBlock(session: session, face: face, comments: comments);
      case ExerciseDetailBlock.statistics:
        return _StatisticsBlock(session: session, face: face);
      case ExerciseDetailBlock.chat:
        return SizedBox(
          height: 480,
          child: AiChatScreen(
            scope: AiScope.session,
            session: session,
            exercise: exercise,
            face: face,
            embedded: true,
            coachMode: true,
          ),
        );
    }
  }

  void _openBlockSettings(BuildContext context) {
    final blocks = context.read<ExerciseDetailViewModel>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: blocks,
        child: const _BlockSettingsSheet(),
      ),
    );
  }
}

class _BlockSettingsSheet extends StatelessWidget {
  const _BlockSettingsSheet();

  @override
  Widget build(BuildContext context) {
    final blocks = context.watch<ExerciseDetailViewModel>();
    return FractionallySizedBox(
      heightFactor: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('Удержать и перетащить — поменять порядок блоков. Переключателем справа блок скрывается.'),
          ),
          Expanded(
            child: ReorderableListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              onReorder: blocks.move,
              children: [
                for (final b in blocks.order)
                  Card(
                    key: ValueKey(b),
                    child: ListTile(
                      title: Text(b.title),
                      subtitle: blocks.isHidden(b) ? const Text('скрыт') : null,
                      trailing: Switch(
                        value: !blocks.isHidden(b),
                        onChanged: b.canHide ? (v) => blocks.setHidden(b, !v) : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetBlock extends StatelessWidget {
  const _TargetBlock();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final total = vm.session.shots.length;
    // 98% ширины экрана, квадрат (решение пользователя) — раньше высота
    // была задана отдельно от ширины (0.3 высоты экрана), из-за чего
    // мишень оказывалась мельче, чем у спортсмена на рабочем столе, и
    // зум внутри такой маленькой рамки выглядел как "зум в окне", а не
    // как настоящее увеличение мишени.
    final side = MediaQuery.sizeOf(context).width * 0.98;
    return Column(
      children: [
        Center(
          child: SizedBox(width: side, height: side, child: const ClipRect(child: TargetCanvas(tapToSelect: true))),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: FractionallySizedBox(
            widthFactor: 0.9,
            // Вдвое тоньше, чем на рабочем столе тренировки (решение
            // пользователя) — здесь колесо только листает уже
            // записанные выстрелы, а не главный элемент экрана.
            child: ShotWheel(
              value: vm.selectedIndex < 0 ? 0 : vm.selectedIndex,
              minValue: 0,
              maxValue: total == 0 ? 0 : total - 1,
              enabled: total > 1,
              onChanged: vm.selectIndex,
              height: 26,
            ),
          ),
        ),
      ],
    );
  }
}

class _SeriesBlock extends StatelessWidget {
  final TrainingSession session;
  final TargetFace face;
  final List<Map<String, dynamic>> comments;
  const _SeriesBlock({required this.session, required this.face, required this.comments});

  @override
  Widget build(BuildContext context) {
    final stats = ShotAnalytics(session.shots, face).seriesStats;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text('Серии', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (stats.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Серий нет'))
            else
              for (final s in stats)
                ListTile(
                  title: Text('Серия ${s.seriesNo}'),
                  subtitle: Text('Сумма ${s.total.toStringAsFixed(1)} · среднее ${s.average.toStringAsFixed(1)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _SeriesShotsScreen(
                      session: session,
                      face: face,
                      seriesNo: s.seriesNo,
                      comments: comments,
                    ),
                  )),
                ),
          ],
        ),
      ),
    );
  }
}

class _SeriesShotsScreen extends StatelessWidget {
  final TrainingSession session;
  final TargetFace face;
  final int seriesNo;
  final List<Map<String, dynamic>> comments;

  const _SeriesShotsScreen({
    required this.session,
    required this.face,
    required this.seriesNo,
    required this.comments,
  });

  @override
  Widget build(BuildContext context) {
    final shots = session.shots.where((s) => s.seriesNo == seriesNo).toList();
    return Scaffold(
      appBar: AppBar(title: Text('Серия $seriesNo')),
      body: shots.isEmpty
          ? const EmptyState(icon: Icons.list_alt, text: 'В серии нет выстрелов')
          : ListView.builder(
              itemCount: shots.length,
              itemBuilder: (context, i) {
                final shot = shots[i];
                return ListTile(
                  title: Text('№${shot.shotNumber} — ${shot.score.toStringAsFixed(1)}'),
                  subtitle: Text('X: ${shot.xMm.toStringAsFixed(1)} мм · Y: ${shot.yMm.toStringAsFixed(1)} мм'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _SingleShotScreen(shot: shot, face: face, comments: comments),
                  )),
                );
              },
            ),
    );
  }
}

/// Мишень с местом ОДНОГО попадания + заметка к нему, если есть — та же
/// идея, что у спортсмена, только заметки уже загружены заранее (одним
/// `fetchComments` на всю тренировку) и фильтруются здесь по shot_id, а
/// не читаются заново из локальной базы.
class _SingleShotScreen extends StatelessWidget {
  final Shot shot;
  final TargetFace face;
  final List<Map<String, dynamic>> comments;

  const _SingleShotScreen({required this.shot, required this.face, required this.comments});

  @override
  Widget build(BuildContext context) {
    final colors = context.watch<PersonalizationViewModel>().scheme;
    final notes = comments.where((c) => c['level'] == 'shot' && '${c['shot_id']}' == shot.id).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    return Scaffold(
      appBar: AppBar(title: Text('Выстрел №${shot.shotNumber}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(
              painter: TargetPainter(
                face: face,
                colors: colors,
                visibleShots: [shot],
                selectedShot: shot,
                currentSeriesNo: shot.seriesNo,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Результат: ${shot.score.toStringAsFixed(1)}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text('Заметки', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          if (notes.isEmpty)
            const Text('Заметок к этому выстрелу нет')
          else
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${n['author_role'] == 'coach' ? 'Тренер' : 'Спортсмен'}: '
                      '${DateFormat('dd.MM HH:mm').format(DateTime.tryParse('${n['created_at']}')?.toLocal() ?? DateTime.now())}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text('${n['text']}'),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _StatisticsBlock extends StatelessWidget {
  final TrainingSession session;
  final TargetFace face;
  const _StatisticsBlock({required this.session, required this.face});

  @override
  Widget build(BuildContext context) {
    return AnalyticsPanel(
      shots: session.countingShots,
      face: face,
      dynamics: session.countingShots.isEmpty
          ? null
          : [
              AnalyticsDynamics(
                title: 'Динамика выстрелов',
                subtitle: '',
                points: session.countingShots,
                maxY: 10.9,
              ),
            ],
    );
  }
}
