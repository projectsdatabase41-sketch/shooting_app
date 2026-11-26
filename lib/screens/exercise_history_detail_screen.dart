import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../widgets/glass_route.dart';
import '../widgets/glass_pill.dart';
import '../widgets/series_shot_tiles.dart';
import '../widgets/ai_gate.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../logic/ai_context.dart';
import '../logic/session_logic.dart';
import '../logic/shot_analytics.dart';
import '../models/exercise.dart';
import '../models/exercise_detail_block.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../models/target_color_scheme.dart';
import '../painters/analytics_painters.dart';
import '../painters/target_painter.dart';
import '../painters/score_graph_painter.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/exercise_detail_view_model.dart';
import '../state/personalization_view_model.dart';
import '../state/target_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/analytics_panel.dart' show AnalyticsDynamics;
import '../widgets/comments_thread.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';
import '../widgets/shot_wheel.dart';
import '../widgets/sius_panel.dart';
import '../widgets/stats_blocks.dart';
import '../widgets/target_canvas.dart';
import 'ai_chat_screen.dart';
import 'target_screen.dart';

/// Просмотр ОДНОЙ прошлой тренировки (раздел 8 ТЗ) — вертикальный список
/// перестраиваемых/скрываемых блоков вместо рабочего стола со страницами
/// (`TargetScreen`): здесь только смотрят, не тренируются, и постранично
/// листать нечего.
///
/// Шапка (название + сумма) в список блоков не входит — пользователь
/// явно отвёл ей отдельное фиксированное место.
///
/// Раскладка (отзыв владельца 23.11, п. 1): на портрете — как раньше,
/// одной колонкой; в альбомной ориентации и на планшете (ширина 700+)
/// мишень закреплена слева, а справа — прокручиваемая колонка со
/// списком выстрелов и аналитикой.
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

class _DetailBody extends StatefulWidget {
  final TrainingSession session;
  final Exercise exercise;
  final TargetFace face;

  const _DetailBody({required this.session, required this.exercise, required this.face});

  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> {
  /// Перестроить экран после правки выстрела МИМО вью-модели: удаление
  /// из списка справа (отзыв владельца 23.11, п. 5) делаем напрямую
  /// через `SessionLogic.deleteShot` + `store.upsertSession`, а
  /// `notifyListeners` у вью-модели защищённый и извне недоступен —
  /// иначе список и мишень остались бы со старыми выстрелами.
  void _onShotEdited() => setState(() {});

  @override
  void initState() {
    super.initState();
    // Отзыв 26.11 (d81c7608, 80b9adff): при открытии истории мишень сразу
    // приближается под пробоины — не нужно щипать вручную. Если есть сильный
    // отрыв, масштаб подбирается так, чтобы он остался виден.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final vm = context.read<TargetViewModel>();
      final shots = vm.session.countingShots;
      if (shots.isNotEmpty) vm.zoomToShots(shots);
    });
  }

  /// Панель «как SIUS» для wide-режима истории (владелец 24.11): тот же
  /// виджет, что в финалах, но без обратного отсчёта — вместо него
  /// прошедшее время тренировки (от старта до последнего выстрела, в
  /// простое паузы не считаются).
  Widget _siusPanel(BuildContext context, TrainingSession session) {
    final exercise = widget.exercise;
    final rows = <SiusShotRow>[
      for (final s in session.shots)
        SiusShotRow(
          number: s.shotNumber,
          series: s.seriesNo,
          score: s.score,
          point: Offset(s.xMm, s.yMm),
          // Пристрелка (fitting): серия упражнения с counts == false, а для
          // старых тренировок — флаг самого выстрела.
          sighting: !s.counts || !exercise.countsSeries(s.seriesNo),
        ),
    ];
    // Лимиты серий из описания упражнения; серия, ограниченная временем,
    // лимита по числу выстрелов не имеет (−1: завершённой станет, только
    // когда началась следующая). Для упражнений старого вида — пары
    // totalShots/seriesSize.
    List<int>? limits;
    if (exercise.series.isNotEmpty) {
      limits = [for (final spec in exercise.series) spec.shotCount ?? -1];
    } else if (exercise.seriesSize > 0 && exercise.totalShots > 0) {
      limits = List.filled(
          (exercise.totalShots / exercise.seriesSize).ceil(),
          exercise.seriesSize);
    }
    // Подпись текущей серии — по последнему зачётному выстрелу.
    final counting = session.countingShots;
    final currentSeries =
        counting.isEmpty ? 0 : counting.last.seriesNo;
    final totalSeries = limits?.length ??
        (exercise.seriesSize > 0
            ? (exercise.totalShots / exercise.seriesSize).ceil()
            : 0);
    final seriesLabel = currentSeries > 0
        ? tr('Серия {n} из {m}', {'n': currentSeries, 'm': totalSeries})
        : null;
    // Прошедшее время: старт → финиш (или последний выстрел), минус
    // паузы. Даты отсюда уже из прошлого — тип времени «помер».
    String? timeText;
    final end = session.finishedAt ??
        (session.shots.isEmpty ? null : session.shots.last.time);
    if (session.startedAt != null && end != null) {
      var s =
          end.difference(session.startedAt!).inSeconds.clamp(0, 99999);
      for (final p in session.pauseIntervals) {
        // Пауза может быть ещё не закрыта (без resumedAt): её длительность
        // неизвестна — в прошедшее время не считаем, нулями не «удлиняем».
        final resumed = p.resumedAt;
        if (resumed != null) s -= resumed.difference(p.pausedAt).inSeconds;
      }
      s = s.clamp(0, 999999);
      timeText = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    }
    return SiusPanel(
      face: widget.face,
      shots: rows,
      title: exercise.label,
      seriesLabel: seriesLabel,
      timeText: timeText,
      seriesShots: (limits != null && limits.every((n) => n > 0)) ? limits : null,
      lastFiveMode: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocks = context.watch<ExerciseDetailViewModel>();
    // Читаем вью-модель целиком (а не только multiTouch): избранное
    // переключается через неё, и список выстрелов должен перестраиваться.
    final vm = context.watch<TargetViewModel>();
    // Текущая тренировка — из вью-модели, а не из widget.session: после
    // удаления выстрела в ней актуальный список (widget.session остался бы
    // тем же объектом, с которым экран открыли).
    final session = vm.session;
    // Пока на мишени два пальца (щипок для зума), список блоков не
    // должен листаться сам — иначе прокрутка страницы забирает жест
    // раньше, чем TargetCanvas успевает опознать его как зум (решение
    // пользователя). Тот же флаг, что уже гасит свайп PageView на
    // рабочем столе тренировки (target_screen.dart).
    final multiTouch = vm.multiTouch;
    final total = session.totalScore;

    final size = MediaQuery.sizeOf(context);
    // Отзыв владельца 23.11, п. 1: горизонтальная раскладка для всех
    // моделей — в альбомной ориентации и на планшете мишень слева,
    // аналитика справа. Порог ширины 700 — планшеты и широкие складни.
    final wide = MediaQuery.orientationOf(context) == Orientation.landscape || size.width >= 700;
    final topInset = MediaQuery.paddingOf(context).top;

    final scrollPhysics = multiTouch ? const NeverScrollableScrollPhysics() : null;
    final listPadding = EdgeInsets.fromLTRB(12, topInset + GlassHeader.height + 4, 12, 24);

    if (!wide) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _appBar(context),
        body: ListView(
          physics: scrollPhysics,
          padding: listPadding,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(tr('{p} очка ({p2})', {'p': total.toStringAsFixed(1), 'p2': total.round()})),
            ),
            for (final block in blocks.visible) ...[
              // «Результат по сериям» — под мишенью (отзыв 7dacac57); в
              // статистике он повторяется только если блок серий скрыт,
              // иначе получался дубль в двух местах.
              _buildBlock(context, block,
                  showSeriesBlock: !blocks.visible.contains(ExerciseDetailBlock.series)),
              const SizedBox(height: 16),
            ],
            // В узкой раскладке списка выстрелов нет нигде, кроме этой
            // карточки: на широком экране его заменила лента SIUS справа
            // (отзыв 25.11, cb00e7a5), но удалять/помечать выстрелы
            // по-прежнему нужно (там же — избранное и комментарии).
            _ShotsListBlock(onChanged: _onShotEdited),
          ],
        ),
      );
    }

    // Широкая раскладка (отзыв владельца 23.11, п. 1 и 5): мишень слева,
    // справа — список выстрелов (вместо блока серий) и аналитика.
    // Ширину мишени ограничиваем с двух сторон: узкие складни и высокие
    // телефоны в альбомной — слева веером, короткие — не отъедали у
    // правой колонки больше половины экрана.
    // Отзыв b4868a41: мишень ~70% ширины, список выстрелов ~30% справа.
    // Ограничиваем разумно: на узких экранах не меньше 240 px, но не больше
    // 70% ширины.
    final targetPaneWidth = math.max(240.0, math.min(0.7 * size.width, 640.0));
    final targetCanvasHeight = math.max(
      240.0,
      math.min(targetPaneWidth, size.height * 0.7),
    );
    // Блоки мишени и серий в правой колонке не повторяются: мишень —
    // слева, серии заменены списком выстрелов (отзыв владельца 23.11, п. 5).
    final rightBlocks = [
      for (final block in blocks.visible)
        if (block != ExerciseDetailBlock.target && block != ExerciseDetailBlock.series) block,
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _appBar(context),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: targetPaneWidth,
            child: SingleChildScrollView(
              physics: scrollPhysics,
              padding: EdgeInsets.fromLTRB(12, topInset + GlassHeader.height + 4, 0, 24),
              // «Результат по сериям» — сразу под мишенью и колесом, а не в
              // правой колонке (отзыв 25.11, a0d4d65c).
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TargetBlock(faceRadiusHeight: targetCanvasHeight),
                  const SizedBox(height: 12),
                  _SeriesBlock(session: session, face: widget.face),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              physics: scrollPhysics,
              padding: listPadding,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(tr('{p} очка ({p2})', {'p': total.toStringAsFixed(1), 'p2': total.round()})),
                ),
                // Владелец 24.11 («экран как SIUS»): на широком экране в
                // правой колонке — панель со списком выстрелов, суммами
                // серий и числом центральных. Обратного отсчёта здесь нет —
                // тренировка уже прошла; показываем прошедшее время.
                // Лента выстрелов — одна на всю правую колонку (отзыв 25.11,
                // cb00e7a5: «список выстрелов вертикальной лентой + суммы
                // серий после каждой, пристрелку не считать»). Второй,
                // отдельный список ниже больше не нужен — он дублировал те
                // же выстрелы (было: панель 280 px + _ShotsListBlock).
                SizedBox(
                  height: math.max(280.0, size.height - topInset - GlassHeader.height - 80),
                  child: _siusPanel(context, session),
                ),
                const SizedBox(height: 16),
                for (final block in rightBlocks) ...[
                  _buildBlock(context, block, showSeriesBlock: false),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    return GlassHeader(
      title: Text(widget.exercise.label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      actions: [
        // Этот экран только для просмотра — разблокировать тренировку
        // для правки (менять/удалять выстрелы, комментарии) по-прежнему
        // можно на рабочем столе тренировки, как и раньше. Правки через
        // список справа (отзыв 23.11, п. 5) — отдельная история, они не
        // включают рабочий стол.
        GlassCircleButton(
          icon: const BoldIcon(Icons.edit_outlined),
          tooltip: tr('Редактировать'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TargetScreen(session: widget.session, exercise: widget.exercise),
          )),
        ),
        GlassCircleButton(
          icon: const BoldIcon(Icons.tune),
          tooltip: tr('Порядок блоков'),
          onTap: () => _openBlockSettings(context),
        ),
      ],
    );
  }

  Widget _buildBlock(BuildContext context, ExerciseDetailBlock block, {required bool showSeriesBlock}) {
    switch (block) {
      case ExerciseDetailBlock.target:
        return _TargetBlock(faceRadiusHeight: MediaQuery.sizeOf(context).height * 0.3);
      case ExerciseDetailBlock.series:
        return _SeriesBlock(session: context.watch<TargetViewModel>().session, face: widget.face);
      case ExerciseDetailBlock.statistics:
        return _StatisticsBlock(
          session: context.watch<TargetViewModel>().session,
          face: widget.face,
          // На широком экране «Результат по сериям» не показываем —
          // вместо него список выстрелов справа от мишени (отзыв
          // владельца 23.11, п. 5).
          showSeries: showSeriesBlock,
        );
      case ExerciseDetailBlock.chat:
        if (!aiModuleOn(context)) return const SizedBox.shrink();
        return SizedBox(
          height: 480,
          child: AiChatScreen(
            scope: AiScope.session,
            session: context.watch<TargetViewModel>().session,
            exercise: widget.exercise,
            face: widget.face,
            embedded: true,
          ),
        );
    }
  }

  void _openBlockSettings(BuildContext context) {
    final blocks = context.read<ExerciseDetailViewModel>();
    showGlassSheet(
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
            // Вдвое тоньше, как и у тренера в точно таком же экране
            // просмотра (coach_exercise_detail_screen.dart) — здесь
            // колесо только листает уже записанные выстрелы, а не
            // главный элемент экрана, как на рабочем столе тренировки.
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
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    SeriesNotesBadge(
                      count: [for (final sh in session.shots.where((x) => x.seriesNo == s.seriesNo)) CommentsRepository(context.read<AppDataStore>().db).forShot(session.id, sh.id).length]
                          .fold(0, (a, b) => a + b),
                    ),
                    const Icon(Icons.chevron_right),
                  ]),
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
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Серия {seriesNo}', {'seriesNo': seriesNo}),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: shots.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(top: topInset + GlassHeader.height),
              children: [EmptyState(icon: Icons.list_alt, text: tr('В серии нет выстрелов'))],
            )
          : ListView.builder(
              padding: EdgeInsets.only(top: topInset + GlassHeader.height),
              itemCount: shots.length,
              itemBuilder: (context, i) {
                final shot = shots[i];
                return SeriesShotRow(
                  shot: shot,
                  notes: CommentsRepository(context.read<AppDataStore>().db).forShot(session.id, shot.id).length,
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
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Выстрел {n}', {'n': shot.shotNumber}),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 16),
        children: [
          // Отзыв ca1307d4: центр мишени — по центру, а пробоина этого
          // выстрела «доигрывается» зумом: мишень приближена и сдвинута так,
          // чтобы отметка стояла ровно в центре кадра.
          SizedBox(
            height: 260,
            child: _SingleShotTarget(shot: shot, face: face, colors: colors),
          ),
          const SizedBox(height: 12),
          SingleShotInfo(shot: shot, face: face, colors: colors),
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

  /// На широкой раскладке блок «Результат по сериям» не показывается —
  /// вместо него список выстрелов справа от мишени (отзыв владельца
  /// 23.11, п. 5).
  final bool showSeries;

  const _StatisticsBlock({required this.session, required this.face, required this.showSeries});

  @override
  Widget build(BuildContext context) {
    return _HistoryAnalyticsPanel(
      shots: session.countingShots,
      face: face,
      showSeries: showSeries,
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

/// Список выстрелов справа от мишени на широкой раскладке (отзыв
/// владельца 23.11, п. 5): строка — «№ · значение», тап по строке
/// открывает меню действий — удалить, в избранное, комментарий. Функцию
/// нажатия несут сами строки, поэтому блок «Серии» здесь не нужен
/// (отзыв владельца 23.11, п. 3).
class _ShotsListBlock extends StatelessWidget {
  /// Сообщить экрану, что выстрел изменён МИМО вью-модели (удаление) —
  /// иначе список и мишень останутся со старыми данными.
  final VoidCallback onChanged;

  const _ShotsListBlock({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final vm = context.watch<TargetViewModel>();
    final session = vm.session;
    final shots = [...session.shots]..sort((x, y) => x.shotNumber.compareTo(y.shotNumber));
    final numbers = theme.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(tr('Выстрелы'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (shots.isEmpty)
              Padding(padding: const EdgeInsets.all(16), child: Text(tr('Выстрелов нет')))
            else
              for (final shot in shots)
                ListTile(
                  dense: true,
                  title: Text(
                    // «№ · значение» — как просил владелец (п. 5 отзыва).
                    '${shot.shotNumber} · ${shot.score.toStringAsFixed(1)}',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (shot.isFavorite) Icon(Icons.star, size: 16, color: cs.tertiary),
                      // Координаты в мм — только у реальных пробоин:
                      // у синтетических точек нули не печатаем.
                      if (shot.xMm != 0 || shot.yMm != 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          tr('{x} / {y} мм', {'x': _signed(shot.xMm), 'y': _signed(shot.yMm)}),
                          style: numbers,
                        ),
                      ],
                    ],
                  ),
                  onTap: () {
                    // Одновременно показываем выстрел на мишени слева.
                    vm.selectIndex(session.shots.indexOf(shot));
                    _ShotActionSheet.show(context, shot, onChanged: onChanged);
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// Знак координаты: плюс показываем явно, минус — типографский (в
  /// столбце цифр дефис читается как перенос). Порог 0.05 — тот же, что
  /// у отклонения СТП.
  static String _signed(double v) {
    final s = v.abs().toStringAsFixed(1);
    if (v > 0.05) return '+$s';
    if (v < -0.05) return '−$s';
    return '0.0';
  }
}

/// Меню действий над ОДНИМ выстрелом из списка справа (отзыв владельца
/// 23.11, п. 5) — то же, что у строки списка `ShotActionsSheet` рабочего
/// стола, но отдельным виджетом: вью-модель этого экрана создана с
/// `isOwnSession: false`, и её `deleteShot()` заблокирован.
class _ShotActionSheet extends StatelessWidget {
  final Shot shot;
  final VoidCallback onChanged;

  const _ShotActionSheet({required this.shot, required this.onChanged});

  static Future<void> show(BuildContext context, Shot shot, {required VoidCallback onChanged}) {
    return showGlassSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<TargetViewModel>(),
        child: _ShotActionSheet(shot: shot, onChanged: onChanged),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    // Выстрел могли уже удалить, пока меню оставалось открытым, —
    // тогда ничего не предлагаем: перечитываем по id, как это делает
    // `ShotActionsSheet`.
    final stillThere = vm.session.shots.where((s) => s.id == shot.id).toList();
    if (stillThere.isEmpty) return const SizedBox.shrink();
    final current = stillThere.first;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              tr('Выстрел №{shotNumber} · {p}', {'shotNumber': current.shotNumber, 'p': current.score.toStringAsFixed(1)}),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.comment_outlined),
            title: Text(tr('Комментарий')),
            // Тот же поток заметок, что и на рабочем столе тренировки:
            // читать и добавлять комментарии можно прямо отсюда.
            onTap: () {
              Navigator.of(context).pop();
              CommentsThreadSheet.showForShot(context, current.id);
            },
          ),
          ListTile(
            leading: Icon(current.isFavorite ? Icons.star : Icons.star_border),
            title: Text(current.isFavorite ? tr('Убрать из избранного') : tr('В избранное')),
            onTap: () {
              // toggleFavorite не завязан на canEditShots — работает и на
              // экране просмотра (isOwnSession: false).
              vm.toggleFavorite(current.id);
              Navigator.of(context).pop();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(tr('Удалить')),
            onTap: () => _confirmDelete(context),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final vm = context.read<TargetViewModel>();
    final stillThere = vm.session.shots.where((s) => s.id == shot.id).toList();
    if (stillThere.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Удалить выстрел №{shotNumber}?', {'shotNumber': stillThere.first.shotNumber})),
        // То же поведение, что и на рабочем столе: выстрел не стирается
        // безвозвратно, а уходит в корзину тренировки.
        content: Text(tr('Выстрел уйдёт в корзину тренировки.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Отмена')),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    // Вью-модель этого экрана создана с isOwnSession: false, поэтому её
    // deleteShot() ничего не делает (canEditShots == false) — этот экран
    // задумывался как просмотр. Отзыв владельца 23.11 (п. 5) просит
    // удалять выстрел прямо из списка справа, поэтому повторяем те же
    // вызовы, что и внутри deleteShot(): SessionLogic.deleteShot +
    // store.upsertSession. Поле vm.session обновляем (оно снаружи
    // доступно для записи), чтобы мишень слева не рисовала удалённую
    // пробоину.
    final updated = SessionLogic.deleteShot(vm.session, shot.id);
    vm.session = updated;
    vm.noteExternalEdit();
    context.read<AppDataStore>().upsertSession(updated);
    onChanged();
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// Аналитика ЭТОГО экрана — суженная копия общей `AnalyticsPanel`.
///
/// Копия, а не параметр общего виджета: той же панелью пользуется экран
/// статистики, менять её нельзя (правки ограничены этим файлом).
/// Отличия по отзывам владельца 23.11:
///  - плитки-«итог» (StatTile) убраны совсем (п. 3), отклонение СТП
///    переехало в легенде блока «СТП и кучность» — с графической
///    стрелкой вместо символа в тексте (п. 2);
///  - «Внутри десятки» (распределение по десятым) убрано (п. 3): когда
///    все выстрелы легли в десятку, блока распределения здесь нет вовсе;
///  - у «Результата по сериям» убрана подсказка «Нажмите на серию —
///    откроются её выстрелы» (п. 4);
///  - `showSeries == false` — блок серий не показывается (широкая
///    раскладка, п. 5: вместо него список выстрелов справа от мишени).
class _HistoryAnalyticsPanel extends StatefulWidget {
  final List<Shot> shots;
  final TargetFace face;

  /// График динамики: точки — результаты каждого выстрела этой
  /// тренировки (панель статистики подставляет сюда другие срезы).
  final List<AnalyticsDynamics>? dynamics;

  /// Показывать ли блок «Результат по сериям».
  final bool showSeries;

  const _HistoryAnalyticsPanel({
    required this.shots,
    required this.face,
    required this.showSeries,
    this.dynamics,
  });

  @override
  State<_HistoryAnalyticsPanel> createState() => _HistoryAnalyticsPanelState();
}

class _HistoryAnalyticsPanelState extends State<_HistoryAnalyticsPanel> {
  /// Текущий режим графика динамики — по одному на срез здесь всегда
  /// одна тренировка, но переключатель оставляем: блок перестраивается
  /// из общих настроек (stats_blocks.dart) вместе со статистикой.
  int _mode = 0;

  /// Открытая (раскрытая под кнопками) серия. `null` — списка не видно.
  int? _openSeries;

  void _toggleSeries(int seriesNo) {
    setState(() => _openSeries = _openSeries == seriesNo ? null : seriesNo);
  }

  List<Shot> get shots => widget.shots;
  TargetFace get face => widget.face;

  // ---- Порядок и включённость блоков — те же настройки, что и у
  // панели статистики (stats_blocks.dart): у экрана просмотра своих нет.
  @override
  void initState() {
    super.initState();
    StatsBlocks.revision.addListener(_onBlocksChanged);
  }

  @override
  void dispose() {
    StatsBlocks.revision.removeListener(_onBlocksChanged);
    super.dispose();
  }

  void _onBlocksChanged() {
    if (mounted) setState(() {});
  }

  List<(String, Widget)> _ordered(List<(String, Widget)> blocks) {
    final db = context.read<AppDataStore>().db;
    final pref = StatsBlocks.order(db);
    final out = [for (final b in blocks) if (StatsBlocks.visible(db, b.$1)) b];
    out.sort((x, y) => pref.indexOf(x.$1).compareTo(pref.indexOf(y.$1)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = AppTheme.accentFor(cs);

    if (shots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: EmptyState(
          icon: Icons.query_stats,
          text: tr('В этом срезе пока нет выстрелов'),
        ),
      );
    }

    final a = ShotAnalytics(shots, face);
    final modes = widget.dynamics ?? const <AnalyticsDynamics>[];
    final series = a.seriesStats;
    final mode = modes.isEmpty ? 0 : _mode % modes.length;

    final blocks = <(String, Widget)>[
      // Блок «Обзор» удалён (отзывы 25.11: 1bffae2d, 953867d4, a0d4d65c —
      // «блоки обзор убрать вообще, это лишнее»): те же итоги уже есть в
      // панели SIUS справа и в блоках динамики/СТП ниже.
      if (modes.isNotEmpty)
        ('dynamics', _block(
          title: modes[mode].title,
          subtitle: modes.length > 1
              ? tr('{p} · нажмите, чтобы сменить', {'p': modes[mode].subtitle})
              : modes[mode].subtitle,
          child: GestureDetector(
            onTap: modes.length > 1 ? () => setState(() => _mode = mode + 1) : null,
            child: _chartCard(
              height: modes[mode].verticalXLabels ? 220 : 190,
              child: CustomPaint(
                painter: ScoreGraphPainter(
                  shots: modes[mode].points,
                  lineColor: accent,
                  axisColor: cs.onSurfaceVariant,
                  maxY: modes[mode].maxY,
                  minY: modes[mode].effectiveMinY,
                  yTickStep: (modes[mode].maxY - modes[mode].effectiveMinY) / 5,
                  xLabels: modes[mode].xLabels,
                  verticalXLabels: modes[mode].verticalXLabels,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        )),
      // «Внутри десятки» убрано (отзыв владельца 23.11, п. 3): когда все
      // выстрелы легли в десятку, блока распределения здесь нет вовсе.
      // По габаритам блок оставлен — владелец жаловался именно на
      // распределение десятых внутри десятки, а не на габариты.
      if (!a.allInTen)
        ('dist', _block(
          title: tr('Распределение по габаритам'),
          subtitle: '',
          child: _chartCard(
            height: _ringChartHeight(a),
            child: CustomPaint(
              painter: RingDistributionPainter(
                rows: _ringRows(a),
                barColor: cs.primary,
                axisColor: cs.onSurfaceVariant,
                labelWidth: 22,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        )),
      ('group', _block(
        title: tr('СТП и кучность'),
        subtitle: _groupSubtitle(a),
        child: _chartCard(
          height: 240,
          child: Row(
            children: [
              Expanded(
                child: CustomPaint(
                  painter: GroupScatterPainter(
                    shots: shots,
                    face: face,
                    meanPointMm: a.meanPoint,
                    meanRadiusMm: a.meanRadiusMm,
                    spreadCenterMm: a.spreadCircleCenterMm,
                    spreadRadiusMm: a.extremeSpreadMm == null ? null : a.extremeSpreadMm! / 2,
                    cep50Mm: a.cepRadiusMm(0.5),
                    cep90Mm: a.cepRadiusMm(0.9),
                    showNumbers: shots.length <= 30,
                    shotColor: cs.primary,
                    meanColor: accent,
                    ringColor: cs.onSurfaceVariant,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 140, child: _groupLegend(context, a, accent)),
            ],
          ),
        ),
      )),
      if (widget.showSeries && series.length > 1)
        ('series', _block(
          // Отзыв владельца 23.11, п. 4: подсказку «Нажмите на серию —
          // откроются её выстрелы» убрали — серия и так открывается по
          // нажатию, лишняя строка только удлиняла блок.
          title: tr('Результат по сериям'),
          subtitle: '',
          child: _SeriesButtons(shots: shots, openSeries: _openSeries, onToggle: _toggleSeries),
        )),
    ];
    final ordered = _ordered(blocks);

    // Горизонтальная ориентация — карточки в два столбца вместо одной
    // длинной ленты (решение пользователя), как и в общей панели.
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = MediaQuery.orientationOf(context) == Orientation.landscape && constraints.maxWidth > 600;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final b in ordered) Padding(padding: const EdgeInsets.only(bottom: 24), child: b.$2)],
          );
        }
        const gap = 16.0;
        final colWidth = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final b in ordered) SizedBox(width: colWidth, child: b.$2)],
        );
      },
    );
  }

  /// Заголовок + подпись + карточка одним блоком — единица раскладки.
  Widget _block({required String title, required String subtitle, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  /// Строки гистограммы по габаритам — блок «Внутри десятки» на этом
  /// экране убран (отзыв владельца 23.11, п. 3), поэтому ряды по десятым
  /// здесь не строятся вовсе.
  List<({String label, int count})> _ringRows(ShotAnalytics a) {
    final min = _minRing(a);
    return [
      for (var r = 10; r >= min; r--) (label: '$r', count: a.ringCounts[r] ?? 0),
    ];
  }

  Widget _groupLegend(BuildContext context, ShotAnalytics a, Color accent) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final spread = a.extremeSpreadMm;

    TextStyle valueStyle([Color? color]) =>
        theme.textTheme.titleSmall?.copyWith(color: color ?? cs.onSurface) ?? const TextStyle();

    Widget row(String label, Widget value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 2),
            value,
          ],
        ),
      );
    }

    final cep50 = a.cepRadiusMm(0.5);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Отзыв владельца 23.11, п. 2 и 3: плитки с отклонением СТП
        // («итог»-плитки) на этом экране убраны, поэтому значения по
        // осям живут здесь, а рядом — стрелка направления виджетом из
        // темы, а не символом в тексте.
        row(
          tr('Отклонение СТП'),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(_meanXyText(a), style: valueStyle(), overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 6),
              _DirectionArrow(a.meanPoint),
            ],
          ),
        ),
        row(tr('Смещение СТП'), Text(tr('{p} мм', {'p': a.meanOffsetMm.toStringAsFixed(1)}), style: valueStyle(accent))),
        // «Средний разброс» был размытым термином: под разбросом
        // понимают и это, и поперечник. Радиус СТП (Mean Radius) —
        // общепринятое название именно этой величины.
        row(tr('Радиус СТП'), Text(tr('{p} мм', {'p': a.meanRadiusMm.toStringAsFixed(1)}), style: valueStyle())),
        if (cep50 != null) row(tr('Половина в'), Text(tr('{p} мм', {'p': cep50.toStringAsFixed(1)}), style: valueStyle())),
        row(
          tr('Поперечник'),
          Text(
            spread == null
                ? tr('— (>{extremeSpreadLimit} выстр.)', {'extremeSpreadLimit': ShotAnalytics.extremeSpreadLimit})
                : tr('{p} мм', {'p': spread.toStringAsFixed(1)}),
            style: valueStyle(),
          ),
        ),
      ],
    );
  }

  /// Отклонение СТП по осям со знаком: «X +0.4 · Y −1.2».
  ///
  /// Минус — типографский, а не дефис: в столбце цифр дефис читается
  /// как перенос. Порог 0.05 общий у текста и у стрелки (`_DirectionArrow`):
  /// раньше текст гасил ось с 0.05, а стрелка считалась по полному
  /// расстоянию — «0.0 / −0.1» рисовало стрелку туда, куда текст
  /// показывал ноль (отзыв владельца 23.11, п. 2).
  static String _meanXyText(ShotAnalytics a) {
    String v(double x) {
      final s = x.abs().toStringAsFixed(1);
      if (x > 0.05) return '+$s';
      if (x < -0.05) return '−$s';
      return '0.0';
    }

    return 'X ${v(a.meanPoint.dx)} · Y ${v(a.meanPoint.dy)}';
  }

  String _groupSubtitle(ShotAnalytics a) {
    final spread = a.extremeSpreadMm;
    // Символ-стрелку сноса из подписи убрали: направление показывает
    // графическая стрелка в легенде (отзыв владельца 23.11, п. 2).
    return spread == null
        ? tr('Кольца: радиус СТП и половина попаданий')
        : tr('Пунктир — поперечник {p} мм', {'p': spread.toStringAsFixed(1)});
  }

  /// Нижняя граница гистограммы: показываем до самого низкого габарита,
  /// в который реально попадали, но не меньше пяти строк — иначе на
  /// хорошей серии график из двух полос выглядит обрубком.
  int _minRing(ShotAnalytics a) {
    var min = 10;
    for (final e in a.ringCounts.entries) {
      if (e.value > 0 && e.key < min) min = e.key;
    }
    return math.min(min, 6);
  }

  double _ringChartHeight(ShotAnalytics a) {
    final rows = 10 - _minRing(a) + 1;
    return rows * 22.0 + 8;
  }

  Widget _chartCard({required double height, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 10),
        child: SizedBox(height: height, child: child),
      ),
    );
  }
}

/// Стрелка направления смещения СТП (отзыв владельца 23.11, п. 2):
/// графический значок из темы, повёрнутый на ТОЧНЫЙ угол, вместо
/// символа-стрелки из `directionArrow`, квантованного по восьми румбам.
///
/// Правило знаков — как на мишени: положительный X — вправо,
/// положительный Y — вверх. Угол = atan2(dx, dy): 0 — вверх, растёт по
/// часовой стрелке (Transform.rotate крутит именно так). В мёртвой зоне
/// — обе оси меньше 0.05 мм — стрелка не рисуется вовсе: «0.0 / −0.1»
/// по обеим осям раньше рисовало стрелку в сторону, хотя текст показывал
/// ноль.
class _DirectionArrow extends StatelessWidget {
  /// Смещение СТП в мм от центра мишени.
  final Offset mm;

  /// Тот же порог, что у текста отклонения (_meanXyText).
  static const double deadZoneMm = 0.05;

  const _DirectionArrow(this.mm);

  @override
  Widget build(BuildContext context) {
    if (mm.dx.abs() < deadZoneMm && mm.dy.abs() < deadZoneMm) return const SizedBox.shrink();
    return Transform.rotate(
      angle: math.atan2(mm.dx, mm.dy),
      child: Icon(
        Icons.arrow_upward_rounded,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Ряд кнопок «номер серии · сумма» с раскрывающимся списком выстрелов —
/// копия `_SeriesButtons` общей панели (`analytics_panel.dart`, нельзя
/// менять: им пользуется экран статистики), но в корне этого файла.
class _SeriesButtons extends StatelessWidget {
  final List<Shot> shots;

  /// Номер открытой серии; `null` — список выстрелов не показан.
  final int? openSeries;

  /// Переключение открытой серии — состоянием владеет панель, чтобы
  /// перерисовки блока не сбрасывали выбор при смене среза.
  final ValueChanged<int> onToggle;

  const _SeriesButtons({
    required this.shots,
    required this.openSeries,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // Группировка та же, что в `ShotAnalytics.seriesStats`, но здесь нужны
    // сами выстрелы: серия выводится списком по номеру выстрела.
    final bySeries = <int, List<Shot>>{};
    for (final s in shots) {
      bySeries.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final nos = bySeries.keys.toList()..sort();
    if (nos.isEmpty) return const SizedBox.shrink();

    // Открытая серия может исчезнуть вместе со сменой среза — тогда
    // показываем только кнопки, а не падаем на null.
    final openRow = openSeries == null ? null : bySeries[openSeries];
    final opened =
        openRow == null ? const <Shot>[] : ([...openRow]..sort((x, y) => x.shotNumber.compareTo(y.shotNumber)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Кнопки идут друг за другом с переносом: серий бывает и шесть,
            // и десять, а `Row` на телефоне даёт переполнение.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in nos) _seriesButton(context, n, bySeries[n]!),
              ],
            ),
            if (opened.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                tr('Выстрелы серии {n}', {'n': openSeries}),
                style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final s in opened) _shotRow(context, s),
            ],
          ],
        ),
      ),
    );
  }

  /// Кнопка серии: номер и сумма с десятыми. Нажатая подсвечивается
  /// акцентом темы — иначе непонятно, к какой кнопке относится список ниже.
  Widget _seriesButton(BuildContext context, int seriesNo, List<Shot> row) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sum = row.fold<double>(0, (acc, s) => acc + s.score);
    final active = openSeries == seriesNo;

    return OutlinedButton(
      onPressed: () => onToggle(seriesNo),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        foregroundColor: active ? cs.primary : cs.onSurface,
        backgroundColor: active ? cs.primary.withValues(alpha: 0.14) : null,
        side: BorderSide(
          color: active ? cs.primary : cs.outlineVariant.withValues(alpha: 0.6),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
      ),
      child: Text(
        '$seriesNo · ${sum.toStringAsFixed(1)}',
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  /// Строка списка: номер выстрела, результат и — если координаты реально
  /// есть — X/Y в мм. У синтетических точек координат нет, поэтому нули
  /// не печатаем: «0.0 / 0.0 мм» читалось бы как настоящая пробоина в
  /// центре.
  Widget _shotRow(BuildContext context, Shot s) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final base = theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final hasMm = s.xMm != 0 || s.yMm != 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('${s.shotNumber}', style: base?.copyWith(color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            width: 46,
            child: Text(
              s.score.toStringAsFixed(1),
              style: base?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              hasMm ? tr('{x} / {y} мм', {'x': _signed(s.xMm), 'y': _signed(s.yMm)}) : '',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: base?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Знак координаты: плюс показываем явно, минус — типографский (в столбце
  /// цифр дефис читается как перенос). Порог 0.05 — как в `_meanXyText`.
  static String _signed(double v) {
    final s = v.abs().toStringAsFixed(1);
    if (v > 0.05) return '+$s';
    if (v < -0.05) return '−$s';
    return '0.0';
  }
}

/// Мишень выстрела с автозумом: пробоина ставится в центр кадра.
class _SingleShotTarget extends StatelessWidget {
  final Shot shot;
  final TargetFace face;
  final TargetColorScheme colors;
  const _SingleShotTarget({required this.shot, required this.face, required this.colors});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final side = box.biggest.shortestSide;
      final far = shot.radiusMm;
      final zoom = (face.faceRadiusMm * 0.8 / (far <= 0.5 ? 1.0 : far)).clamp(1.0, 6.9).toDouble();
      final k = side / 2 * zoom / face.faceRadiusMm;
      final pan = Offset(-shot.xMm * k, shot.yMm * k);
      final center = Offset(box.maxWidth / 2, box.maxHeight / 2) + pan;
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: CustomPaint(
              painter: TargetPainter(
                face: face,
                colors: colors,
                visibleShots: const [],
                selectedShot: null,
                currentSeriesNo: shot.seriesNo,
                zoom: zoom,
                pan: pan,
                denseLabels: true,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _ShotDotPainter(center: center),
            ),
          ),
        ]),
      );
    });
  }
}

/// Отметка выстрела на мишени одного выстрела: точка с ореолом.
class _ShotDotPainter extends CustomPainter {
  final Offset center;
  const _ShotDotPainter({required this.center});

  @override
  void paint(Canvas canvas, Size size) {
    final halo = Paint()..color = const Color(0xFFFFD54F).withValues(alpha: 0.35);
    final dot = Paint()..color = const Color(0xFFFF6D00);
    final ring = Paint()
      ..color = const Color(0xFFFFF8E1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, 12, halo);
    canvas.drawCircle(center, 6, dot);
    canvas.drawCircle(center, 6, ring);
  }

  @override
  bool shouldRepaint(_ShotDotPainter old) => old.center != center;
}
