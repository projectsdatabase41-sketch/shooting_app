import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../logic/ai_context.dart';
import '../logic/shot_photo_detection.dart';
import '../models/exercise.dart';
import '../models/comment.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../models/workspace_page.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';
import '../state/workspace_view_model.dart';
import '../widgets/analytics_panel.dart';
import '../widgets/comments_thread.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/shot_list_sheet.dart';
import '../widgets/shot_wheel.dart';
import '../widgets/target_canvas.dart';
import 'ai_chat_screen.dart';
import 'photo_scan_screen.dart';

/// Рабочий стол тренировки.
///
/// Устроен как домашний экран Android (решение пользователя): страницы
/// листаются свайпом, порядок меняется перетаскиванием, лишние
/// прячутся. Мишень — одна из страниц, а не единственный экран.
///
/// Что осталось НЕПОДВИЖНЫМ поверх страниц: название упражнения,
/// пауза/завершение и таймеры. Пользователь просил именно так — эти
/// кнопки нужны в любой момент, независимо от того, на какой странице
/// он сейчас, и уезжать вместе со свайпом им нельзя.
///
/// Имя класса прежнее (`TargetScreen`), чтобы не переписывать три места
/// вызова: снаружи это по-прежнему «открыть тренировку».
class TargetScreen extends StatelessWidget {
  final TrainingSession session;
  final Exercise exercise;
  final bool isOwnSession;
  final bool embedded;

  const TargetScreen({
    super.key,
    required this.session,
    required this.exercise,
    this.isOwnSession = true,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    final face = TargetFace.byCode(exercise.targetFaceCode);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TargetViewModel>(
          create: (_) => TargetViewModel(
            store: store,
            session: session,
            exercise: exercise,
            face: face,
            isOwnSession: isOwnSession,
          ),
        ),
        // Раскладка рабочего стола — общая для всех тренировок, но
        // объект создаётся здесь: держать его в корне приложения ради
        // одного экрана незачем, а состояние он читает из базы.
        ChangeNotifierProvider<WorkspaceViewModel>(
          create: (_) => WorkspaceViewModel(store.db),
        ),
      ],
      child: const _WorkspaceBody(),
    );
  }
}

class _WorkspaceBody extends StatefulWidget {
  const _WorkspaceBody();

  @override
  State<_WorkspaceBody> createState() => _WorkspaceBodyState();
}

class _WorkspaceBodyState extends State<_WorkspaceBody> {
  PageController? _pages;
  int _current = 0;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _ensureController(int initial) {
    if (_pages != null) return;
    _current = initial;
    _pages = PageController(initialPage: initial);
  }

  void _goTo(int index) {
    _pages?.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final workspace = context.watch<WorkspaceViewModel>();
    final pages = workspace.visible;
    _ensureController(workspace.targetIndex);

    // Индекс мог уехать за границы, если страницу спрятали, пока мы
    // на ней стояли.
    final safeCurrent = _current.clamp(0, pages.length - 1);

    return PopScope(
      // Системный «назад» сначала возвращает на мишень и только со
      // страницы мишени выходит из тренировки.
      //
      // Раньше «назад» сворачивал приложение целиком: жест уходил
      // системе, потому что перехватывать его было некому.
      canPop: safeCurrent == workspace.targetIndex,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goTo(workspace.targetIndex);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(vm.exercise.name),
          actions: [
            // Сброс зума — раньше был только жестом (щипок обратно), а
            // щипок легко "залипал" на максимуме, если пальцы не сводить
            // ровно по той же линии. Кнопка — гарантированный выход
            // независимо от того, как повёл себя жест.
            if (vm.zoom != 1.0 || vm.panX != 0 || vm.panY != 0)
              IconButton(
                icon: const Icon(Icons.zoom_out_map),
                tooltip: 'Сбросить зум',
                onPressed: vm.resetZoom,
              ),
            if (vm.canEdit)
              IconButton(
                icon: Icon(vm.isEditing ? Icons.remove_red_eye_outlined : Icons.edit_outlined),
                tooltip: vm.isEditing ? 'Просмотр' : 'Правка',
                onPressed: () => _toggleEditMode(vm),
              ),
            IconButton(
              icon: const Icon(Icons.grid_view),
              tooltip: 'Страницы',
              onPressed: () => _openOverview(context),
            ),
          ],
        ),
        body: Column(
          children: [
            // Управление тренировкой — над страницами и неподвижно.
            if (vm.showTrainingControls) const _TrainingControlsBar(),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _current = i),
                // Страницы не листаются в двух случаях. Во время
                // правки — палец на мишени тянет пробоину, и
                // горизонтальное движение не должно уносить на
                // соседнюю страницу. И пока на мишени два пальца — это
                // щипок для зума: пальцы при сведении всегда смещаются
                // вбок, и горизонтальную составляющую PageView считал
                // своей, из-за чего зум то и дело уезжал на соседнюю
                // страницу.
                physics: vm.isEditing || vm.multiTouch
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemBuilder: (context, i) => _pageBody(pages[i], vm),
              ),
            ),
            // Точки НАД нижним краем: у самой кромки экрана
            // вертикальный свайп перехватывает Android своим жестом
            // «назад/домой», и обзор почти не открывался.
            _PageDots(count: pages.length, current: safeCurrent, onOverview: () => _openOverview(context)),
          ],
        ),
      ),
    );
  }

  Widget _pageBody(WorkspacePage page, TargetViewModel vm) {
    switch (page) {
      case WorkspacePage.target:
        return const _TargetPage();
      case WorkspacePage.statistics:
        return _StatisticsPage(
          session: vm.session,
          face: vm.face,
          exerciseName: vm.exercise.name,
        );
      case WorkspacePage.shots:
        return const ShotListSheet();
      case WorkspacePage.assistant:
        return AiChatScreen(
          scope: AiScope.session,
          session: vm.session,
          exercise: vm.exercise,
          face: vm.face,
          shot: vm.selectedShot,
          embedded: true,
        );
      case WorkspacePage.notes:
        return const CommentsThreadSheet(level: CommentLevel.session);
      case WorkspacePage.coach:
        return const CommentsThreadSheet(level: CommentLevel.coach);
    }
  }

  void _toggleEditMode(TargetViewModel vm) {
    if (vm.isEditing) {
      vm.cancelEditing();
    } else if (vm.selectedShot != null) {
      vm.beginMoveSelected();
    } else {
      vm.beginAddNew();
    }
  }

  /// Обзор страниц — как список запущенных приложений в Android.
  void _openOverview(BuildContext context) {
    final workspace = context.read<WorkspaceViewModel>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: workspace,
        child: _WorkspaceOverview(
          onSelect: (page) {
            final index = workspace.visible.indexOf(page);
            if (index >= 0) _goTo(index);
          },
        ),
      ),
    );
  }
}

/// Точки-индикаторы страниц плюс подъём обзора свайпом вверх.
///
/// Полоса тонкая и живёт под колесом: тянуть вверх от края экрана —
/// привычный жест, а на самих страницах вертикальный свайп занят
/// прокруткой содержимого и перехватывать его нельзя.
class _PageDots extends StatelessWidget {
  final int count;
  final int current;
  final VoidCallback onOverview;

  const _PageDots({required this.count, required this.current, required this.onOverview});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -200) onOverview();
      },
      onTap: onOverview,
      child: Padding(
        // Отступ снизу уводит полосу из зоны системного жеста Android.
        padding: const EdgeInsets.only(bottom: 18),
        child: SizedBox(
          height: 34,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                Container(
                  width: i == current ? 18 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i == current ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Обзор: порядок страниц перетаскиванием, скрытые — отдельным списком.
class _WorkspaceOverview extends StatelessWidget {
  final void Function(WorkspacePage) onSelect;

  const _WorkspaceOverview({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<WorkspaceViewModel>();
    final theme = Theme.of(context);

    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Страницы', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Удержать и перетащить — поменять порядок. '
              'Переключателем справа страница убирается с рабочего стола, '
              'но не удаляется.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ReorderableListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              onReorder: workspace.move,
              children: [
                for (final page in workspace.order)
                  Card(
                    key: ValueKey(page),
                    child: ListTile(
                      leading: Icon(_iconFor(page)),
                      title: Text(page.title),
                      subtitle: workspace.isHidden(page) ? const Text('скрыта') : null,
                      onTap: workspace.isHidden(page)
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              onSelect(page);
                            },
                      trailing: Switch(
                        value: !workspace.isHidden(page),
                        onChanged: page.canHide
                            ? (v) => workspace.setHidden(page, !v)
                            : null,
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

  static IconData _iconFor(WorkspacePage page) => switch (page) {
        WorkspacePage.target => Icons.adjust,
        WorkspacePage.statistics => Icons.insights_outlined,
        WorkspacePage.shots => Icons.list,
        WorkspacePage.assistant => Icons.auto_awesome_outlined,
        WorkspacePage.notes => Icons.sticky_note_2_outlined,
        WorkspacePage.coach => Icons.supervisor_account_outlined,
      };
}

/// Страница мишени: холст, панель правки и колесо.
class _TargetPage extends StatelessWidget {
  const _TargetPage();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    return Column(
      children: [
        // Рамка вокруг мишени.
        //
        // Без обрезки увеличенная мишень вылезала за свою страницу и
        // наползала на соседнюю — при листании получался «затык».
        // ClipRect держит её внутри отведённой области: рамка масштаб
        // не меняет, мишень растёт внутри неё.
        const Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: ClipRect(child: TargetCanvas()),
          ),
        ),
        if (vm.isEditing) const _EditActionBar() else const _ShotActionBar(),
        const _ShotWheelBar(),
      ],
    );
  }
}

/// Страница «Статистика» рабочего стола — разбор текущей тренировки с
/// переключателем серий.
///
/// Раньше это была шторка поверх мишени. Теперь — обычная страница, на
/// которую переходят свайпом: пользователь просил листать между
/// мишенью, разбором и ассистентом, а шторка поверх экрана листаться не
/// умеет и закрывает мишень целиком.
class _StatisticsPage extends StatefulWidget {
  final TrainingSession session;
  final TargetFace face;
  final String exerciseName;

  const _StatisticsPage({
    required this.session,
    required this.face,
    required this.exerciseName,
  });

  @override
  State<_StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<_StatisticsPage> {
  int? _seriesNo;

  @override
  Widget build(BuildContext context) {
    // Пристрелка в разбор не идёт — только зачётные выстрелы.
    final all = widget.session.countingShots;
    final seriesNos = all.map((s) => s.seriesNo).toSet().toList()..sort();
    final shots = _seriesNo == null ? all : all.where((s) => s.seriesNo == _seriesNo).toList();

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(widget.exerciseName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (seriesNos.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<int>(
                initialValue: seriesNos.contains(_seriesNo) ? _seriesNo : null,
                decoration: const InputDecoration(labelText: 'Серия'),
                items: [
                  const DropdownMenuItem<int>(value: null, child: Text('Все серии')),
                  for (final n in seriesNos) DropdownMenuItem(value: n, child: Text('Серия $n')),
                ],
                onChanged: (v) => setState(() => _seriesNo = v),
              ),
            ),
          AnalyticsPanel(
            shots: shots,
            face: widget.face,
            showSeries: _seriesNo == null,
            dynamics: shots.isEmpty
                ? null
                : [
                    AnalyticsDynamics(
                      title: _seriesNo == null ? 'Динамика выстрелов' : 'Динамика серии $_seriesNo',
                      subtitle: '',
                      points: shots,
                      maxY: 10.9,
                    ),
                  ],
          ),
        ],
    );
  }
}

/// Полоса старт/пауза/финиш + оба таймера (раздел 6 ТЗ) — только в
/// режиме спортсмена, не в "дневнике" тренера.
class _TrainingControlsBar extends StatelessWidget {
  const _TrainingControlsBar();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final status = vm.session.status;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildActionButton(context, vm, status),
                const SizedBox(width: 12),
                Text('Общее: ${_fmt(vm.elapsed)}', style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Text('С посл. выстрела: ${vm.sinceLastShot == null ? '—' : _fmt(vm.sinceLastShot!)}', style: const TextStyle(fontSize: 12)),
              ],
            ),
            const _CurrentSeriesLine(),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, TargetViewModel vm, SessionStatus status) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case SessionStatus.notStarted:
        return Raised3DButton(dense: true, label: 'Начать', baseColor: cs.primary, onTap: vm.start);
      case SessionStatus.running:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Raised3DButton(dense: true, label: 'Пауза', baseColor: cs.secondary, onTap: vm.pause),
          const SizedBox(width: 8),
          Raised3DButton(dense: true, label: 'Завершить', baseColor: cs.error, onTap: vm.finish),
        ]);
      case SessionStatus.paused:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Raised3DButton(dense: true, label: 'Продолжить', baseColor: cs.secondary, onTap: vm.resume),
          const SizedBox(width: 8),
          Raised3DButton(dense: true, label: 'Завершить', baseColor: cs.error, onTap: vm.finish),
        ]);
      case SessionStatus.finished:
        return const Text('Завершена', style: TextStyle(fontWeight: FontWeight.bold));
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// Строка текущей серии: «Пристрелка · осталось 12:04 · без зачёта».
///
/// Показывается только у упражнений со свободной структурой — там, где
/// серии разные и стрелку надо знать, в какой он сейчас. У обычного
/// «60 по 10» строки нет: она сообщала бы то, что и так видно.
///
/// Истёкшее время — предупреждение, а не запрет: стрелять можно
/// дальше, выстрел ничем не клеймится (решение пользователя — он мог
/// уйти за последнюю секунду).
class _CurrentSeriesLine extends StatelessWidget {
  const _CurrentSeriesLine();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final spec = vm.currentSeriesSpec;
    if (spec == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final parts = <String>['${vm.currentSeriesNo}. ${spec.name}'];

    final left = vm.currentSeriesTimeLeft;
    var expired = false;
    if (left != null) {
      if (left.isNegative) {
        expired = true;
        parts.add('время вышло');
      } else {
        final m = left.inMinutes.remainder(60).toString().padLeft(2, '0');
        final s = left.inSeconds.remainder(60).toString().padLeft(2, '0');
        parts.add('осталось ${left.inHours > 0 ? '${left.inHours}:' : ''}$m:$s');
      }
    } else if (spec.shotCount != null) {
      parts.add('выстрел ${vm.shotsInCurrentSeries + 1} из ${spec.shotCount}');
    }
    if (!spec.counts) parts.add('без зачёта');

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (expired) ...[
            Icon(Icons.timer_off_outlined, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: expired ? theme.colorScheme.error : null,
                fontWeight: expired ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Кнопки действий на самой мишени во время активной правки — ПО
/// МАКЕТАМ (решение пользователя): Добавить/Удалить/Переместить/Отмена
/// + быстрая заметка к выстрелу вместо "Помощь", плюс степперы
/// результата/угла (A.6).
class _EditActionBar extends StatelessWidget {
  const _EditActionBar();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    // Цвета берём из ТЕМЫ приложения, а не из цветовой схемы мишени.
    //
    // Схема мишени — это личная настройка видимости бланка (стрелок
    // подбирает её под своё зрение и освещение), и bottomPanelBg там
    // остался от старой панели значений, которая жила прямо на мишени.
    // Панель под мишенью — обычный элемент интерфейса, и когда она
    // красилась схемой, на светлой схеме получались белые подписи на
    // белом фоне: было видно, что кнопки есть, но не видно какие.
    final cs = Theme.of(context).colorScheme;
    // Заметка — только к уже существующему выстрелу (id есть, и
    // CommentsThreadSheet может к нему обратиться). У черновика новой
    // пробоины id появится только после "Сохранить" — до этого
    // комментировать нечего.
    final shotForNote = vm.isAddingNew ? null : vm.selectedShot;

    return Material(
      color: cs.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // «Удалить» осталось в списке выстрелов: во время
                  // добавления удалять нечего, а при перемещении удобнее
                  // удалять из списка, где виден весь контекст тренировки.
                  //
                  // Сохранить слева, отменить справа — подтверждение
                  // должно стоять там, куда палец идёт по умолчанию.
                  _iconLabel(context, Icons.check, 'Сохранить', vm.confirmEdit, cs.primary),
                  if (shotForNote != null)
                    _iconLabel(
                      context,
                      Icons.comment_outlined,
                      'Заметка',
                      () => CommentsThreadSheet.showForShot(context, shotForNote.id),
                      cs.secondary,
                    ),
                  _iconLabel(context, Icons.close, 'Отменить', vm.cancelEditing, cs.error),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconLabel(BuildContext context, IconData icon, String label, VoidCallback? onTap, Color color) {
    return InkWell(
      onTap: onTap,
      child: Opacity(
        // 0.55, а не 0.4: на 0.4 подпись под иконкой сливалась с фоном
        // и было непонятно, что это вообще за кнопка.
        opacity: onTap == null ? 0.55 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            Text(label, style: TextStyle(color: color, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// Кнопки под мишенью в режиме просмотра: «плюс» и «править».
///
/// Пришли на смену удержанию пальцем. Удержание ставило пробоину и
/// конфликтовало со всем сразу — с щипком, со свайпом страницы, с
/// прокруткой выстрелов; заплатки ловили часть случаев, но на рабочем
/// экране «часть» не годится. Кнопка не срабатывает сама, и это её
/// главное достоинство.
///
/// «Плюс» ставит новую пробоину в центре — дальше её тащат пальцем,
/// доводят компасом или колесом. «Править» берёт последний выстрел:
/// поправляют почти всегда именно его, и лишний выбор в списке ради
/// этого не нужен.
///
/// Обе — ОТДЕЛЬНЫЕ кнопки с объёмным ("3D") нажатием (решение
/// пользователя), а не два тапа внутри одной общей плашки: рельеф и
/// просадка при нажатии видны как раз потому, что у каждой кнопки
/// свой собственный контур и тень, а не общий фон на двоих.
class _ShotActionBar extends StatefulWidget {
  const _ShotActionBar();

  @override
  State<_ShotActionBar> createState() => _ShotActionBarState();
}

class _ShotActionBarState extends State<_ShotActionBar> {
  bool _scanning = false;

  /// Ждёт, пока пользователь не подтвердит/отменит текущий черновик —
  /// нужно, чтобы прогнать несколько найденных на фото пробоин ПО
  /// ОЧЕРЕДИ через обычную панель правки, а не городить для этого
  /// отдельный экран подтверждения: пользователь видит их на настоящей
  /// мишени, тем же способом, что и вручную поставленную пробоину.
  Future<void> _waitUntilEditingDone(TargetViewModel vm) {
    if (!vm.isEditing) return Future.value();
    final completer = Completer<void>();
    void listener() {
      if (!vm.isEditing) {
        vm.removeListener(listener);
        completer.complete();
      }
    }

    vm.addListener(listener);
    return completer.future;
  }

  Future<void> _scanPhoto(BuildContext context, TargetViewModel vm) async {
    setState(() => _scanning = true);
    try {
      final knownHolesMm = [
        for (final s in [...vm.session.shots, ...vm.session.trash]) PixelPoint(s.xMm, s.yMm),
      ];
      final points = await Navigator.of(context).push<List<PixelPoint>>(
        MaterialPageRoute(
          builder: (_) => PhotoScanScreen(face: vm.face, knownHolesMm: knownHolesMm),
        ),
      );
      if (points == null || !context.mounted) return;
      for (final p in points) {
        if (!vm.canAddShotNow) {
          if (context.mounted) showPauseAddHint(context);
          return;
        }
        vm.beginAddNew();
        vm.updateDraftPosition(p.x, p.y);
        await _waitUntilEditingDone(vm);
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    if (!vm.canEdit) return const SizedBox.shrink();

    final hasShots = vm.session.shots.isNotEmpty;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Raised3DButton(
              icon: Icons.add_circle_outline,
              label: 'Выстрел',
              baseColor: Theme.of(context).colorScheme.primary,
              onTap: () {
                // На паузе позже минутного окна выстрел не добавляется.
                // Молча ничего не делать нельзя — кнопка выглядела бы
                // сломанной, поэтому объясняем, что надо продолжить.
                if (!vm.canAddShotNow) {
                  showPauseAddHint(context);
                  return;
                }
                vm.beginAddNew();
              },
            ),
            Raised3DButton(
              icon: Icons.edit_location_alt_outlined,
              label: 'Править',
              baseColor: Theme.of(context).colorScheme.secondary,
              onTap: hasShots
                  ? () {
                      vm.selectIndex(vm.session.shots.length - 1);
                      vm.beginMoveSelected();
                    }
                  : null,
            ),
            Raised3DButton(
              icon: Icons.photo_camera_outlined,
              label: 'Фото',
              baseColor: Theme.of(context).colorScheme.tertiary,
              onTap: _scanning ? null : () => _scanPhoto(context, vm),
            ),
          ],
        ),
      ),
    );
  }
}

/// Колесо под мишенью — единственный постоянный элемент под ней после
/// того, как нижняя панель значений уехала на углы бланка.
///
/// Один и тот же барабан работает в двух режимах (решение пользователя:
/// «пусть этот слайдер будет и без редактирования, но отвечает за
/// переход к предыдущему и следующему выстрелу»):
///
/// - **правка** — подбор десятой доли результата у черновика;
/// - **просмотр** — перелистывание выстрелов.
///
/// Направление в обоих случаях одинаковое: слева направо — назад,
/// справа налево — вперёд.
class _ShotWheelBar extends StatelessWidget {
  const _ShotWheelBar();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final total = vm.session.shots.length;

    final Widget wheel;
    if (vm.isEditing) {
      // Колесо двигает пробоину по её лучу в обе стороны: вправо-влево
      // от центра, на одну десятую долю за щелчок, через границы колец.
      // Ограничение «только внутри своего габарита» убрано — из-за него
      // выстрел на 9.0 крутился лишь в сторону 9.9.
      wheel = ShotWheel(
        value: vm.draftInwardSteps,
        minValue: 0,
        maxValue: vm.maxDraftSteps,
        enabled: vm.maxDraftSteps > 0,
        onChanged: vm.setDraftInwardSteps,
      );
    } else {
      final index = vm.selectedIndex;
      wheel = ShotWheel(
        value: index < 0 ? 0 : index,
        minValue: 0,
        maxValue: total == 0 ? 0 : total - 1,
        enabled: total > 1,
        onChanged: vm.selectIndex,
      );
    }

    // Фон прозрачный: полоса под колесом сливается с фоном экрана.
    // Раньше здесь стоял bottomPanelBg из цветовой схемы мишени — на
    // светлой схеме под тёмным барабаном получалась белая плашка,
    // которая ни к чему не относилась.
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          // 90% ширины экрана (решение пользователя) — колесо тем
          // чувствительнее к жесту, чем оно шире, а по краям остаётся
          // поле, чтобы барабан не упирался в рамку окна.
          child: FractionallySizedBox(
            widthFactor: 0.9,
            child: wheel,
          ),
        ),
      ),
    );
  }
}
