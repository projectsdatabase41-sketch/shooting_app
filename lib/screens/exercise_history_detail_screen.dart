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
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/exercise_detail_view_model.dart';
import '../state/personalization_view_model.dart';
import '../state/target_view_model.dart';
import '../painters/target_painter.dart';
import '../widgets/analytics_panel.dart';
import '../widgets/empty_state.dart';
import '../widgets/shot_wheel.dart';
import '../widgets/target_canvas.dart';
import 'ai_chat_screen.dart';
import 'target_screen.dart';
import '../i18n/i18n.dart';

/// Просмотр ОДНОЙ прошлой тренировки (раздел 8 ТЗ) — вертикальный список
/// перестраиваемых/скрываемых блоков вместо рабочего стола со страницами
/// (`TargetScreen`): здесь только смотрят, не тренируются, и постранично
/// листать нечего.
///
/// Шапка (название + сумма) в список блоков не входит — пользователь
/// явно отвёл ей отдельное фиксированное место.
class ExerciseHistoryDetailScreen extends StatelessWidget {
  final TrainingSession session;
  final Exercise exercise;

  const ExerciseHistoryDetailScreen({super.key, required this.session, required this.exercise});

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    final face = TargetFace.byCode(exercise.targetFaceCode);
    return MultiProvider(
      providers: [
        // isOwnSession: false — тот же флаг, что и у тренера, смотрящего
        // чужую тренировку: отключает таймер и контролы записи, оставляя
        // только навигацию по уже записанным выстрелам.
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
      child: _DetailBody(session: session, exercise: exercise, face: face),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final TrainingSession session;
  final Exercise exercise;
  final TargetFace face;

  const _DetailBody({required this.session, required this.exercise, required this.face});

  @override
  Widget build(BuildContext context) {
    final blocks = context.watch<ExerciseDetailViewModel>();
    // Пока на мишени два пальца (щипок для зума), список блоков не
    // должен листаться сам — иначе прокрутка страницы забирает жест
    // раньше, чем TargetCanvas успевает опознать его как зум (решение
    // пользователя). Тот же флаг, что уже гасит свайп PageView на
    // рабочем столе тренировки (target_screen.dart).
    final multiTouch = context.watch<TargetViewModel>().multiTouch;
    final total = session.totalScore;

    return Scaffold(
      appBar: AppBar(
        title: Text(exercise.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(tr('{p} очка ({p2})', {'p': total.toStringAsFixed(1), 'p2': total.round()})),
          ),
        ),
        actions: [
          // Этот экран только для просмотра — разблокировать тренировку
          // для правки (менять/удалять выстрелы, комментарии) по-прежнему
          // можно на рабочем столе тренировки, как и раньше.
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr('Редактировать'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TargetScreen(session: session, exercise: exercise),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: tr('Порядок блоков'),
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
        return _TargetBlock(faceRadiusHeight: MediaQuery.sizeOf(context).height * 0.3);
      case ExerciseDetailBlock.series:
        return _SeriesBlock(session: session, face: face);
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

/// Настройка порядка/видимости блоков — тот же приём, что и у обзора
/// страниц рабочего стола тренировки (`_WorkspaceOverview`).
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(tr('Удержать и перетащить — поменять порядок блоков. Переключателем справа блок скрывается.')),
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
                      subtitle: blocks.isHidden(b) ? Text(tr('скрыт')) : null,
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

/// Блок "Мишень" — та же мишень+колесо, что на рабочем столе тренировки
/// (`TargetCanvas`/`ShotWheel`), только в половину высоты и без панели
/// добавления выстрела: здесь только листают уже записанные.
class _TargetBlock extends StatelessWidget {
  final double faceRadiusHeight;
  const _TargetBlock({required this.faceRadiusHeight});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final total = vm.session.shots.length;
    return Column(
      children: [
        SizedBox(
          height: faceRadiusHeight,
          child: const ClipRect(child: TargetCanvas(tapToSelect: true)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FractionallySizedBox(
            widthFactor: 0.9,
            child: ShotWheel(
              value: vm.selectedIndex < 0 ? 0 : vm.selectedIndex,
              minValue: 0,
              maxValue: total == 0 ? 0 : total - 1,
              enabled: total > 1,
              onChanged: vm.selectIndex,
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
  const _SeriesBlock({required this.session, required this.face});

  @override
  Widget build(BuildContext context) {
    final stats = ShotAnalytics(session.shots, face).seriesStats;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(tr('Серии'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (stats.isEmpty)
              Padding(padding: const EdgeInsets.all(16), child: Text(tr('Серий нет')))
            else
              for (final s in stats)
                ListTile(
                  title: Text(tr('Серия {seriesNo}', {'seriesNo': s.seriesNo})),
                  subtitle: Text(tr('Сумма {p} · среднее {p2}', {'p': s.total.toStringAsFixed(1), 'p2': s.average.toStringAsFixed(1)})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _SeriesShotsScreen(
                      session: session,
                      face: face,
                      seriesNo: s.seriesNo,
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

  const _SeriesShotsScreen({required this.session, required this.face, required this.seriesNo});

  @override
  Widget build(BuildContext context) {
    final shots = session.shots.where((s) => s.seriesNo == seriesNo).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Серия {seriesNo}', {'seriesNo': seriesNo}))),
      body: shots.isEmpty
          ? EmptyState(icon: Icons.list_alt, text: tr('В серии нет выстрелов'))
          : ListView.builder(
              itemCount: shots.length,
              itemBuilder: (context, i) {
                final shot = shots[i];
                return ListTile(
                  title: Text('№${shot.shotNumber} — ${shot.score.toStringAsFixed(1)}'),
                  subtitle: Text(tr('X: {p} мм · Y: {p2} мм', {'p': shot.xMm.toStringAsFixed(1), 'p2': shot.yMm.toStringAsFixed(1)})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _SingleShotScreen(sessionId: session.id, shot: shot, face: face),
                  )),
                );
              },
            ),
    );
  }
}

/// Мишень с местом ОДНОГО попадания + заметка к нему, если есть —
/// статичный `TargetPainter` напрямую, без жестового слоя `TargetCanvas`:
/// листать здесь нечего, показывается ровно один выбранный выстрел.
class _SingleShotScreen extends StatelessWidget {
  final String sessionId;
  final Shot shot;
  final TargetFace face;

  const _SingleShotScreen({required this.sessionId, required this.shot, required this.face});

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    final colors = context.watch<PersonalizationViewModel>().scheme;
    final notes = CommentsRepository(store.db).forShot(sessionId, shot.id);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Выстрел №{shotNumber}', {'shotNumber': shot.shotNumber}))),
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
          Text(tr('Результат: {p}', {'p': shot.score.toStringAsFixed(1)}), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(tr('Заметки'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          if (notes.isEmpty)
            Text(tr('Заметок к этому выстрелу нет'))
          else
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat('dd.MM HH:mm').format(n.createdAt.toLocal()),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(n.text),
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
                title: tr('Динамика выстрелов'),
                subtitle: '',
                points: session.countingShots,
                maxY: 10.9,
              ),
            ],
    );
  }
}
