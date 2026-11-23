import '../widgets/glass_route.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import '../widgets/ai_gate.dart';
import 'focus_training_screen.dart';
import '../voice/clock_shot.dart';
import '../voice/voice_control.dart';
import '../voice/voice_grammar.dart';
import 'package:uuid/uuid.dart';
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
import '../widgets/call_coach_button.dart';
import '../widgets/comments_thread.dart';
import '../widgets/finished_edit_exit_dialog.dart';
import '../widgets/glass_pill.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/shot_list_sheet.dart';
import '../widgets/athlete_coach_chat.dart';
import '../widgets/shot_wheel.dart';
import '../services/comments_repository.dart';
import '../logic/friendly_error.dart' show friendlyErrorDevMode;
import '../widgets/target_canvas.dart';
import '../theme/app_theme.dart';
import 'ai_chat_screen.dart';
import 'photo_scan_screen.dart';
import '../i18n/i18n.dart';

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
      child: _WorkspaceBody(embedded: embedded),
    );
  }
}

/// Мишень этапа задания: только мишень, кнопка выстрела и колесо — без
/// рабочего стола и управления тренировкой. Выстрелы не сохраняются в
/// тренировки ([TargetViewModel.detached]); [onChanged] отдаёт сессию наружу
/// после каждого изменения (задание собирает выстрелы само).
class TaskTargetPanel extends StatelessWidget {
  final TrainingSession session;
  final Exercise exercise;
  final ValueChanged<TrainingSession> onChanged;

  const TaskTargetPanel(
      {super.key,
      required this.session,
      required this.exercise,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    return ChangeNotifierProvider<TargetViewModel>(
      create: (_) {
        final vm = TargetViewModel(
          store: store,
          session: session,
          exercise: exercise,
          face: TargetFace.byCode(exercise.targetFaceCode),
          detached: true,
        );
        if (vm.session.status != SessionStatus.running) vm.start();
        vm.addListener(() => onChanged(vm.session));
        return vm;
      },
      child: const _TargetPage(),
    );
  }
}

class _WorkspaceBody extends StatefulWidget {
  /// Экран открыт внутри главного экрана (вкладка), а не отдельным маршрутом:
  /// тогда после завершения тренировки его закрывает сам главный экран.
  final bool embedded;
  const _WorkspaceBody({this.embedded = false});

  @override
  State<_WorkspaceBody> createState() => _WorkspaceBodyState();
}

class _WorkspaceBodyState extends State<_WorkspaceBody> {
  /// Прокрутка колонки мишени (на десктопе она своя, на мобильном мишень
  /// закреплена и не листается вовсе).
  final _scroll = ScrollController();

  /// Прокрутка выбранного раздела под переключателем. Отдельный контроллер
  /// от [_scroll]: иначе переключение раздела дёргало бы мишень, а «перейти
  /// к мишени» из общего списка сбрасывало бы позицию раздела.
  final _sectionScroll = ScrollController();

  /// Какой раздел показан под переключателем.
  ///
  /// Хранится в состоянии экрана, а не в базе: это временный вид, а не
  /// настройка рабочего стола. `null` — раздел ещё не выбран, тогда работает
  /// значение по умолчанию (см. [_selectedBottom]).
  WorkspacePage? _bottomPage;

  /// Максимальный размер мишени на десктоп/веб (фиксированный лимит, px).
  static const double _maxTargetSizeDesktop = 720.0;


  @override
  void initState() {
    super.initState();
    // Голос: команды тренировки действуют, пока открыт этот экран.
    final vm = context.read<TargetViewModel>();
    VoiceControl.instance.register(this, mode: VoiceMode.training, {
      VoiceAction.placeShot: (i) {
        if (!vm.canAddShotNow) return tr('Сначала начните тренировку');
        final (x, y) = pointForScore(vm.face, i.score!, i.hour!);
        vm.addShotAt(x, y);
        final note = i.text;
        if (note != null && note.isNotEmpty) {
          final store = context.read<AppDataStore>();
          final shot = vm.session.shots.last;
          CommentsRepository(store.db).add(Comment(
            id: const Uuid().v4(),
            sessionId: vm.session.id,
            level: CommentLevel.shot,
            shotId: shot.id,
            authorRole: store.workMode == WorkMode.coach
                ? AuthorRole.coach
                : AuthorRole.athlete,
            text: note,
            createdAt: DateTime.now(),
          ));
          vm.noteExternalEdit();
        }
        return tr('Выстрел {s} на {h} ч',
                {'s': (i.score!).toStringAsFixed(1), 'h': i.hour!.round()}) +
            (note == null || note.isEmpty ? '' : tr(' — заметка сохранена'));
      },
      VoiceAction.trainingStart: (i) {
        if (!vm.canEdit) return tr('Тренировку сейчас начать нельзя');
        vm.start();
        return tr('Тренировка начата');
      },
      VoiceAction.trainingPause: (i) {
        vm.pause();
        return tr('Пауза');
      },
      VoiceAction.trainingResume: (i) {
        vm.resume();
        return tr('Продолжаем');
      },
      VoiceAction.trainingFinish: (i) async {
        // Завершение подтверждается на экране: ошибка распознавания не должна закрыть тренировку.
        final ok = await showGlassDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('Завершить тренировку?')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('Отмена'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('Завершить'))),
            ],
          ),
        );
        if (ok == true) {
          vm.finish();
          if (!widget.embedded && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr('Тренировка завершена'))));
            Navigator.of(context).maybePop();
          }
        }
        return ok == true ? tr('Тренировка завершена') : tr('Отменено');
      },
      VoiceAction.undoShot: (i) {
        if (vm.session.shots.isEmpty) return tr('Выстрелов нет');
        vm.undoLastShot();
        return tr('Последний выстрел отменён');
      },
      VoiceAction.focusMode: (i) {
        FocusTrainingScreen.open(context);
        return tr('Режим концентрации');
      },
      VoiceAction.addNote: (i) {
        final text = i.text;
        if (text == null || text.isEmpty) {
          return tr('Скажите: «заметка» и текст');
        }
        final store = context.read<AppDataStore>();
        final shot = vm.selectedShot ??
            (vm.session.shots.isEmpty ? null : vm.session.shots.last);
        CommentsRepository(store.db).add(Comment(
          id: const Uuid().v4(),
          sessionId: vm.session.id,
          level: shot == null ? CommentLevel.session : CommentLevel.shot,
          shotId: shot?.id,
          authorRole: store.workMode == WorkMode.coach
              ? AuthorRole.coach
              : AuthorRole.athlete,
          text: text,
          createdAt: DateTime.now(),
        ));
        vm.noteExternalEdit();
        return tr('Заметка сохранена');
      },
    });
  }

  @override
  void dispose() {
    VoiceControl.instance.unregister(this);
    _scroll.dispose();
    _sectionScroll.dispose();
    super.dispose();
  }

  /// Выбранный раздел под переключателем.
  ///
  /// По умолчанию — «Статистика», если она доступна и в тренировке есть
  /// зачётные выстрелы: сразу после серии стрелок смотрит разбор, а не
  /// пустой список (решение владельца, отзывы 22.11). Иначе — первый
  /// доступный раздел; нет ни одного — `null`, тогда показываем подсказку.
  WorkspacePage? _selectedBottom(
      List<WorkspacePage> bottomPages, TargetViewModel vm) {
    final picked = _bottomPage;
    if (picked != null && bottomPages.contains(picked)) return picked;
    if (bottomPages.isEmpty) return null;
    if (bottomPages.contains(WorkspacePage.statistics) &&
        vm.session.countingShots.isNotEmpty) {
      return WorkspacePage.statistics;
    }
    return bottomPages.first;
  }

  /// Выбрать раздел полосой-переключателем.
  void _selectBottom(WorkspacePage page) {
    if (_bottomPage == page) return;
    setState(() => _bottomPage = page);
    // Раздел открывается сверху: без сброса он появлялся бы на середине
    // прокрутки предыдущего, и казалось бы, что открылось не то.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sectionScroll.hasClients) _sectionScroll.jumpTo(0);
    });
  }

  /// Тело одного выбранного раздела — то же, что раньше было в общей ленте.
  Widget _bottomSection(
      WorkspacePage page, TargetViewModel vm, double sectionH) {
    // Статистика — плоский блок без вложенного скролла (решение владельца:
    // разбор листается одной страницей, а не окошком внутри окошка).
    if (page == WorkspacePage.statistics) {
      return _StatisticsSection(
        title: page.title,
        child: _pageBody(page, vm),
      );
    }
    // Остальные разделы — в рамке фиксированной высоты: у выстрелов,
    // ассистента, заметок и чата с тренером своя внутренняя прокрутка.
    Widget body = _pageBody(page, vm);
    if (page == WorkspacePage.notes) {
      // У ленты заметок подсветку нажатия гасим: сама лента — не кнопка, а
      // «блик» от касания на полупрозрачных пузырях читался ровно как жалоба
      // «комментарии к тренировке становятся фиолетовыми при пролистывании»
      // (отзывы 22.11, №16). Фон под лентой уже непрозрачный — см. _Section.
      body = Theme(
        data: Theme.of(context).copyWith(
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: body,
      );
    }
    return _Section(
      title: page.title,
      height: sectionH,
      scroll: _sectionScroll,
      child: body,
    );
  }

  /// Прокрутка одного выбранного раздела.
  ///
  /// Индикатор перетаскивания за край выключен намеренно: при коротком
  /// разделе он «заливал» его просвечивающим цветом темы — отзыв 22.11
  /// «комментарии к тренировке становятся фиолетовыми при пролистывании».
  Widget _sectionScrollView({required Widget child}) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
        child: SingleChildScrollView(
          controller: _sectionScroll,
          physics: const ClampingScrollPhysics(),
          child: child,
        ),
      );

  /// Подсказка вместо раздела: все разделы скрыты в «Разделах», а пустое
  /// место под мишенью выглядело бы поломкой.
  Widget _noSectionsHint() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Разделы скрыты. Включите нужные в меню «Разделы».'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );

  void _jumpTo(WorkspacePage page) {
    // Мишень закреплена сверху, поэтому «перейти к мишени» — прокрутить её
    // колонку в начало (на телефоне она и так на виду).
    if (page == WorkspacePage.target) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
      return;
    }
    // Остальные разделы показывает переключатель — «перейти» значит выбрать.
    _selectBottom(page);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final workspace = context.watch<WorkspaceViewModel>();
    // Страница «Тренер» нужна, только если кому-то выдан доступ (есть тренер).
    final hasCoach =
        context.watch<AppDataStore>().shareGrants.any((g) => g.isActive);
    final pages = [
      for (final p in workspace.visible)
        if (p != WorkspacePage.coach || hasCoach) p
    ];
    // ShotListSheet живёт в своём разделе и не видит нашу прокрутку — просит перейти к мишени
    // через вью-модель.
    vm.onJumpToTargetRequested = () => _jumpTo(WorkspacePage.target);


    return PopScope(
      // Если завершённая тренировка была разблокирована и что-то поправили, выход спрашивает —
      // применить правки или вернуть как было (решение пользователя, часть 12).
      canPop: !vm.hasUnsavedFinishedEdits,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleFinishedEditExit(context, vm);
      },
      child: Scaffold(
        appBar: GlassHeader(
          title: Text(vm.exercise.shownName,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
          actions: [
            // Сброс зума — кнопка надёжнее щипка, который мог «залипнуть» на максимуме.
            if (vm.zoom != 1.0 || vm.panX != 0 || vm.panY != 0)
              GlassCircleButton(
                icon: const BoldIcon(Icons.zoom_out_map),
                tooltip: tr('Сбросить зум'),
                onTap: vm.resetZoom,
              ),
            if (vm.isFinishedAndLocked)
              GlassCircleButton(
                icon: const BoldIcon(Icons.lock_outline),
                tooltip: tr('Разблокировать правку завершённой тренировки'),
                onTap: () => _confirmUnlockFinished(context, vm),
              ),
            if (vm.canEditShots && !vm.face.hitMiss)
              GlassCircleButton(
                icon: const BoldIcon(Icons.center_focus_strong),
                tooltip: tr('Режим концентрации'),
                onTap: () => FocusTrainingScreen.open(context),
              ),
            if (vm.canEditShots)
              GlassCircleButton(
                icon: BoldIcon(vm.isEditing
                    ? Icons.remove_red_eye_outlined
                    : Icons.edit_outlined),
                tooltip: vm.isEditing ? tr('Просмотр') : tr('Правка'),
                onTap: () => _toggleEditMode(vm),
              ),
            if (vm.session.status == SessionStatus.running ||
                vm.session.status == SessionStatus.paused)
              CallCoachButton(db: context.read<AppDataStore>().db),
            GlassCircleButton(
              icon: const BoldIcon(Icons.grid_view),
              tooltip: tr('Разделы'),
              onTap: () => _openOverview(context),
            ),
          ],
        ),
        body: Column(
          children: [
            // Управление тренировкой — над разделами и неподвижно.
            if (vm.showTrainingControls) _TrainingControlsBar(embedded: widget.embedded),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  // Определяем, десктоп/веб ли это (широкий экран).
                  final isDesktopOrWeb = kIsWeb ||
                      defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux;

                  // Разделы под переключателем. Мишень в список кнопок не
                  // попадает — она закреплена сверху. Пустую статистику не
                  // рисуем даже кнопкой: зачётных выстрелов нет, показывать
                  // нечего (правило было и в длинной ленте).
                  final bottomPages = <WorkspacePage>[
                    for (final p in pages)
                      if (p != WorkspacePage.target &&
                          !(p == WorkspacePage.statistics &&
                              vm.session.countingShots.isEmpty))
                        p,
                  ];
                  final selected = _selectedBottom(bottomPages, vm);
                  // Рамке раздела нужна фиксированная высота: у выстрелов,
                  // ассистента, заметок и чата с тренером своя прокрутка.
                  final sectionH = math.max(380.0, box.maxHeight * 0.75);

                  if (isDesktopOrWeb) {
                    // Мишень слева: квадрат по высоте экрана, ширина чуть
                    // больше высоты — под отступы и кнопку отмены выстрела.
                    final maxByWidth = box.maxWidth * 0.6;
                    final maxByHeight = box.maxHeight * 0.8;
                    final targetH = math
                        .min(maxByWidth, maxByHeight)
                        .clamp(220.0, _maxTargetSizeDesktop);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Левая колонка: мишень, поле заметки и «крутилка».
                        // Их рисует сам _TargetPage — отдельно больше не
                        // добавляем, иначе под мишенью стоит два поля заметки
                        // и два колеса подряд (так и было раньше).
                        SizedBox(
                          width: targetH * 1.1,
                          child: SingleChildScrollView(
                            controller: _scroll,
                            physics: vm.isEditing || vm.multiTouch
                                ? const NeverScrollableScrollPhysics()
                                : const ClampingScrollPhysics(),
                            child: Column(
                              children: [
                                _TargetPage(height: targetH),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                        // Правая колонка: переключатель и ОДИН выбранный
                        // раздел. Прокрутка всех разделов подряд оставила бы
                        // вторую ленту рядом с переключателем (решение
                        // владельца, отзывы 22.11).
                        Expanded(
                          child: Column(
                            children: [
                              if (bottomPages.isNotEmpty)
                                _SectionsSwitcher(
                                  pages: bottomPages,
                                  selected: selected,
                                  onSelect: _selectBottom,
                                ),
                              Expanded(
                                child: _sectionScrollView(
                                  child: selected == null
                                      ? _noSectionsHint()
                                      : Column(
                                          children: [
                                            _bottomSection(
                                                selected, vm, sectionH),
                                            const SizedBox(height: 24),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  // Мобильный: мишень и «крутилка» закреплены сверху, ниже —
                  // полоса переключателя и только выбранный раздел (решение
                  // владельца, отзывы 22.11). Раньше здесь шла одна длинная
                  // лента всех разделов, и до нужного надо было листать мимо
                  // остальных.
                  //
                  // Высоту мишени считаем от остатка: панель заметки и колесо
                  // под ней занимают своё, полосе переключателя нужно ~48, а
                  // разделу — хотя бы ~150, иначе он не читается. Запас в 24 —
                  // на шрифт крупнее обычного и на строку «Попал/Мимо», чтобы
                  // не получить переполнение колонки.
                  const double switcherH = _SectionsSwitcher.totalHeight;
                  const double sectionMin = 150; // минимум под раздел
                  const double barsSlack = 24; // запас на высоту панелей
                  final double barsH = vm.face.hitMiss ? 190 : 130;
                  final double available =
                      box.maxHeight - switcherH - barsH - sectionMin - barsSlack;
                  // Телефон в альбомной ориентации (высота ~360–430) не
                  // помещает мишень, полосу и раздел одновременно. Тогда не
                  // закрепляем мишень: пусть всё едет одной лентой, иначе
                  // колонка переполняется и Flutter рисует полосатую плашку
                  // поверх экрана.
                  if (available < 160) {
                    return SingleChildScrollView(
                      controller: _scroll,
                      physics: vm.isEditing || vm.multiTouch
                          ? const NeverScrollableScrollPhysics()
                          : const ClampingScrollPhysics(),
                      child: Column(
                        children: [
                          _TargetPage(
                              height: (box.maxHeight * 0.55).clamp(160.0, 320.0)),
                          if (bottomPages.isNotEmpty)
                            _SectionsSwitcher(
                              pages: bottomPages,
                              selected: selected,
                              onSelect: _selectBottom,
                            ),
                          if (selected != null)
                            _bottomSection(selected, vm, sectionH),
                          const SizedBox(height: 24),
                        ],
                      ),
                    );
                  }
                  final double targetH = available.clamp(160.0, 720.0);
                  return Column(
                    children: [
                      _TargetPage(height: targetH),
                      if (bottomPages.isNotEmpty)
                        _SectionsSwitcher(
                          pages: bottomPages,
                          selected: selected,
                          onSelect: _selectBottom,
                        ),
                      Expanded(
                        child: _sectionScrollView(
                          child: selected == null
                              ? _noSectionsHint()
                              : Column(
                                  children: [
                                    _bottomSection(selected, vm, sectionH),
                                    const SizedBox(height: 24),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageBody(WorkspacePage page, TargetViewModel vm) {
    // Фон непрозрачный для всех разделов: на десктопе страницы отображаются
    // поверх обоев с цветной маской, и сквозь полупрозрачные виджеты
    // просвечивал фиолетовый цвет — «синяя накладывается на синюю».
    Widget pageChild;
    switch (page) {
      case WorkspacePage.target:
        pageChild = const _TargetPage();
      case WorkspacePage.statistics:
        pageChild = _StatisticsPage(
          session: vm.session,
          face: vm.face,
          exerciseName: vm.exercise.shownName,
        );
      case WorkspacePage.shots:
        pageChild = const ShotListSheet();
      case WorkspacePage.assistant:
        if (!aiModuleOn(context)) pageChild = const SizedBox.shrink();
        else {
          pageChild = AiChatScreen(
            scope: AiScope.session,
            session: vm.session,
            exercise: vm.exercise,
            face: vm.face,
            shot: vm.selectedShot,
            embedded: true,
          );
        }
      case WorkspacePage.notes:
        pageChild = const CommentsThreadSheet(level: CommentLevel.session);
      case WorkspacePage.coach:
        pageChild = const AthleteCoachChat();
    }
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: pageChild,
    );
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

  Future<void> _confirmUnlockFinished(
      BuildContext context, TargetViewModel vm) async {
    final sure = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Разблокировать правку?')),
        content: Text(
          tr('Тренировка уже завершена. Можно поправить выстрелы задним числом — при выходе с экрана будет ещё раз спрошено, применить изменения или вернуть как было.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Отмена'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr('Разблокировать'))),
        ],
      ),
    );
    if (sure == true) vm.unlockForEditingFinished();
  }

  /// Выход с экрана мишени, когда завершённая тренировка была
  /// разблокирована и в ней что-то поменяли (часть 12 списка).
  Future<void> _handleFinishedEditExit(
      BuildContext context, TargetViewModel vm) async {
    final keep = await confirmFinishedEditExit(context);
    // null — диалог закрыли, не выбрав ничего (тап мимо/системное
    // "назад" внутри диалога): остаёмся на экране, ничего не решаем.
    if (keep == null) return;
    vm.resolveFinishedEditExit(keep: keep);
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Обзор страниц — как список запущенных приложений в Android.
  void _openOverview(BuildContext context) {
    final workspace = context.read<WorkspaceViewModel>();
    showGlassSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: workspace,
        child: _WorkspaceOverview(onSelect: _jumpTo),
      ),
    );
  }
}

/// Раздел длинной страницы тренировки: заголовок и содержимое фиксированной высоты.
class _Section extends StatelessWidget {
  final String title;
  final double height;
  final Widget child;

  /// Прокрутка всей страницы: вложенные списки сами её не листают, поэтому заголовок раздела
  /// тянется пальцем (двигает страницу), а упор вложенного списка в край передаёт остаток
  /// движения странице. Иначе из нижнего раздела нельзя было вернуться вверх.
  final ScrollController scroll;
  const _Section(
      {required this.title,
      required this.height,
      required this.child,
      required this.scroll});

  void _by(double dy) {
    if (!scroll.hasClients) return;
    final p = scroll.position;
    scroll.jumpTo(
        (p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Фон раздела — явный и непрозрачный. Раньше секции стояли на
    // прозрачном фоне экрана, и при прокрутке сквозь них выступала цветная
    // маска обоев: «комментарии к тренировке становятся фиолетовыми»
    // (отзывы 22.11, №16). Подсветку нажатия у самой секции снимаем в
    // _bottomSection: у ленты заметок она не нужна.
    return Material(
      color: cs.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => _by(-d.delta.dy),
            child: Column(children: [
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(children: [
                  Expanded(
                      child: Text(title,
                          style: Theme.of(context).textTheme.titleMedium)),
                  Icon(Icons.drag_handle,
                      size: 20, color: Theme.of(context).hintColor),
                ]),
              ),
            ]),
          ),
          SizedBox(
            height: height,
            child: NotificationListener<OverscrollNotification>(
              onNotification: (n) {
                if (n.metrics.axis == Axis.vertical && n.overscroll != 0) {
                  _by(n.overscroll);
                }
                return false;
              },
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Раздел «Разбор» без фиксированной высоты: заголовок + содержимое,
/// которое растёт по мере необходимости. Используется вместо _Section,
/// чтобы убрать вложенный скролл (плоский список на странице).
class _StatisticsSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _StatisticsSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Тот же непрозрачный фон, что и у _Section: заголовок разбора не должен
    // «краситься» маской обоев при прокрутке (отзывы 22.11, №16).
    return Material(
      color: cs.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(children: [
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
              Icon(Icons.drag_handle,
                  size: 20, color: Theme.of(context).hintColor),
            ]),
          ),
          child,
        ],
      ),
    );
  }
}

/// Полоса-переключатель разделов под мишенью.
///
/// Решение владельца (отзывы 22.11): мишень и «крутилка» остаются на месте, а
/// полоса выбирает, что показать ниже, — вместо длинной ленты всех разделов.
/// Кнопки строятся из уже готового списка доступных страниц, поэтому скрытые
/// в «Разделах» и недоступный «Тренер» сюда не попадают сами собой. Полоса
/// листается вбок: на узком телефоне пять подписей в ширину не влезают, а
/// переносить их на вторую строку нельзя — она отнимает место у раздела.
class _SectionsSwitcher extends StatefulWidget {
  final List<WorkspacePage> pages;
  final WorkspacePage? selected;
  final ValueChanged<WorkspacePage> onSelect;

  const _SectionsSwitcher({
    required this.pages,
    required this.selected,
    required this.onSelect,
  });

  /// Высота кнопки: полоса должна быть компактной (~40 px по макету).
  static const double _height = 40;

  /// Полная высота полосы с отступами — от неё считает раскладка мишени,
  /// поэтому константа одна: раньше в арифметике стояло 48 «на глаз».
  static const double totalHeight = _height + 8;

  @override
  State<_SectionsSwitcher> createState() => _SectionsSwitcherState();
}

class _SectionsSwitcherState extends State<_SectionsSwitcher> {
  /// Ключи кнопок: выбранную надо подтянуть в видимую зону. Полоса
  /// прокручивается вбок, а выбор бывает программным (переход «к разделу»
  /// из обзора), и без подтягивания активная кнопка остаётся за краем.
  final Map<WorkspacePage, GlobalKey> _keys = {};

  @override
  void didUpdateWidget(covariant _SectionsSwitcher old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _revealSelected();
  }

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = widget.selected == null ? null : _keys[widget.selected]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _SectionsSwitcher._height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final page in widget.pages)
              Padding(
                key: _keys.putIfAbsent(page, () => GlobalKey()),
                padding: const EdgeInsets.only(right: 8),
                child: _button(context, page),
              ),
          ],
        ),
      ),
    );
  }

  Widget _button(BuildContext context, WorkspacePage page) {
    final cs = Theme.of(context).colorScheme;
    final active = page == widget.selected;
    final radius = BorderRadius.circular(AppTheme.radiusMedium);
    return SizedBox(
      height: _SectionsSwitcher._height,
      child: Material(
        // Цвета строго из темы, выбранная кнопка — заливка primary/onPrimary.
        // Фон явный и непрозрачный: полоса лежит на фоне экрана, и просвет
        // маски обоев читался бы как «другой» цвет кнопки.
        color: active ? cs.primary : cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
              color: active ? Colors.transparent : cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onSelect(page),
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                page.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? cs.onPrimary : cs.onSurface,
                ),
              ),
            ),
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
            child: Text(tr('Разделы'), style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              tr('Удержать и перетащить — поменять порядок разделов. Переключателем справа раздел убирается со страницы, но не удаляется. Нажатие — перейти к разделу.'),
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
                      subtitle: page == WorkspacePage.target
                          ? Text(tr('закреплена наверху'))
                          : (workspace.isHidden(page)
                              ? Text(tr('скрыта'))
                              : null),
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

/// Мишень, панель правки и колесо. [height] задан на рабочем столе тренировки (мишень касанием,
/// отметка к выстрелу, кнопка отмены выстрела); без него — мишень этапа задания (прежняя раскладка).
class _TargetPage extends StatelessWidget {
  final double? height;
  const _TargetPage({this.height});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final workspace = height != null;
    // Рамка вокруг мишени: ClipRect держит увеличенную мишень внутри отведённой области.
    final canvas = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ClipRect(child: TargetCanvas(addByTouch: workspace)),
    );
    if (!workspace) {
      return Column(
        children: [
          Expanded(child: canvas),
          if (vm.isEditing) const _EditActionBar() else const _ShotActionBar(),
          const _ShotWheelBar(),
        ],
      );
    }
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(child: canvas),
              // Отмена последнего выстрела: маленький кружок справа сверху, не зависит от зума
              // мишени и уезжает вместе со страницей при прокрутке.
              //
              // На пристрелочной серии кружок опускается ниже: в правом верхнем
              // углу стоит загнутый уголок пристрелки, и кружок накрывал его
              // собой — уголок выглядел обрезанным, то есть «не верным»
              // (отзыв 22.11, №7). Сдвиг вниз на 30 px = высота уголка с
              // запасом, поэтому они больше не пересекаются ни при каком зуме.
              if (vm.canEditShots &&
                  vm.session.shots.isNotEmpty &&
                  !vm.isEditing)
                Positioned(
                  top: vm.isSightingSeries ? 40 : 6,
                  right: 8,
                  child: GlassCircleButton(
                    size: 36,
                    icon: const Icon(Icons.undo, size: 18),
                    tooltip: tr('Отменить выстрел'),
                    onTap: vm.undoLastShot,
                  ),
                ),
            ],
          ),
        ),
        if (vm.isEditing) const _EditActionBar() else const _ShotNoteBar(),
        const _ShotWheelBar(),
      ],
    );
  }
}

/// Под мишенью: поле «отметка к выстрелу» (заметка уровня выстрела). У мишеней «попал/мимо» —
/// ещё две кнопки; фотоопределение выстрелов — только в режиме разработчика.
class _ShotNoteBar extends StatefulWidget {
  const _ShotNoteBar();

  @override
  State<_ShotNoteBar> createState() => _ShotNoteBarState();
}

class _ShotNoteBarState extends State<_ShotNoteBar> {
  final _ctl = TextEditingController();
  bool _scanning = false;

  /// Скругление рамки поля «отметка к выстрелу».
  ///
  /// Владелец просил скруглить сильнее («поле ввода с текстом. сначала сделай
  /// выстрел нужно больше округлить рамку», отзывы 22.11, №4): обычные 12 из
  /// темы на этом поле читались как почти прямой угол. 20 — заметное
  /// скругление, но ещё не «таблетка».
  static const _noteBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(20)),
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save(TargetViewModel vm) {
    final text = _ctl.text.trim();
    final shot = vm.selectedShot;
    if (text.isEmpty || shot == null) {
      return;
    }
    final store = context.read<AppDataStore>();
    CommentsRepository(store.db).add(Comment(
      id: const Uuid().v4(),
      sessionId: vm.session.id,
      level: CommentLevel.shot,
      shotId: shot.id,
      authorRole: store.workMode == WorkMode.coach
          ? AuthorRole.coach
          : AuthorRole.athlete,
      text: text,
      createdAt: DateTime.now(),
    ));
    vm.noteExternalEdit();
    _ctl.clear();
    FocusScope.of(context).unfocus();
    setState(() {});
  }

  Future<void> _scanPhoto(TargetViewModel vm) async {
    setState(() => _scanning = true);
    try {
      final knownHolesMm = [
        for (final s in [...vm.session.shots, ...vm.session.trash])
          PixelPoint(s.xMm, s.yMm)
      ];
      final points = await Navigator.of(context).push<List<PixelPoint>>(
        MaterialPageRoute(
            builder: (_) =>
                PhotoScanScreen(face: vm.face, knownHolesMm: knownHolesMm)),
      );
      if (points == null || points.isEmpty || !mounted) return;
      final added = vm.addScannedShots(points);
      if (added < points.length && mounted) showPauseAddHint(context);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final shot = vm.selectedShot;
    final store = context.watch<AppDataStore>();
    final notes = shot == null
        ? const <Comment>[]
        : CommentsRepository(store.db).forShot(vm.session.id, shot.id);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (vm.canEditShots && vm.face.hitMiss)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Raised3DButton(
                    icon: Icons.check_circle_outline,
                    label: tr('Попал'),
                    baseColor: Colors.green.shade700,
                    onTap: () => vm.canAddShotNow
                        ? vm.addHitMiss(true)
                        : showPauseAddHint(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Raised3DButton(
                    icon: Icons.highlight_off,
                    label: tr('Мимо'),
                    baseColor: Colors.red.shade700,
                    onTap: () => vm.canAddShotNow
                        ? vm.addHitMiss(false)
                        : showPauseAddHint(context),
                  ),
                ),
              ]),
            ),
          if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(notes.last.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ctl,
                enabled: shot != null,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _save(vm),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: shot == null
                      ? tr('Сначала сделайте выстрел')
                      : tr('Отметка к выстрелу'),
                  // Крупное скругление у рамки и подсказки «Сначала сделайте
                  // выстрел» (отзывы 22.11, №4) — см. _noteBorder.
                  border: _noteBorder,
                  enabledBorder: _noteBorder,
                  disabledBorder: _noteBorder,
                  focusedBorder: _noteBorder,
                  // Явная заливка: без неё сквозь поле просвечивал фон экрана
                  // с маской обоев, и подсказка «меняла цвет» при прокрутке
                  // (отзывы 22.11, №16).
                  filled: true,
                  fillColor: cs.surfaceContainer,
                  suffixIcon: IconButton(
                    icon: Icon(Icons.send, color: cs.primary),
                    onPressed: shot == null ? null : () => _save(vm),
                  ),
                ),
              ),
            ),
            // Фотоопределение выстрелов — только для разработчика (потом отдельным модулем).
            if (friendlyErrorDevMode && vm.canEditShots) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: tr('Фото мишени'),
                icon: const Icon(Icons.photo_camera_outlined),
                onPressed: _scanning ? null : () => _scanPhoto(vm),
              ),
            ],
          ]),
        ],
      ),
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
    final shots = _seriesNo == null
        ? all
        : all.where((s) => s.seriesNo == _seriesNo).toList();

    // Используем Column вместо ListView: прокрутка обеспечивает родительский
    // SingleChildScrollView, вложенный скролл убираем.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(widget.exerciseName,
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 12),
        if (seriesNos.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: DropdownButtonFormField<int>(
              initialValue: seriesNos.contains(_seriesNo) ? _seriesNo : null,
              decoration: InputDecoration(labelText: tr('Серия')),
              items: [
                DropdownMenuItem<int>(
                    value: null, child: Text(tr('Все серии'))),
                for (final n in seriesNos)
                  DropdownMenuItem(
                      value: n, child: Text(tr('Серия {n}', {'n': n}))),
              ],
              onChanged: (v) => setState(() => _seriesNo = v),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          child: AnalyticsPanel(
            shots: shots,
            face: widget.face,
            showSeries: _seriesNo == null,
            dynamics: shots.isEmpty
                ? null
                : [
                    AnalyticsDynamics(
                      title: _seriesNo == null
                          ? tr('Динамика выстрелов')
                          : tr('Динамика серии {seriesNo}',
                              {'seriesNo': _seriesNo}),
                      subtitle: '',
                      points: shots,
                      maxY: 10.9,
                    ),
                  ],
          ),
        ),
      ],
    );
  }
}

/// Полоса старт/пауза/финиш + оба таймера (раздел 6 ТЗ) — только в
/// режиме спортсмена, не в "дневнике" тренера.
class _TrainingControlsBar extends StatelessWidget {
  /// Внутри главного экрана закрытие после завершения делает сам главный экран.
  final bool embedded;
  const _TrainingControlsBar({this.embedded = false});

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
                Text(tr('Общее: {p}', {'p': _fmt(vm.elapsed)}),
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Text(
                    tr('С посл. выстрела: {p}', {
                      'p': vm.sinceLastShot == null
                          ? '—'
                          : _fmt(vm.sinceLastShot!)
                    }),
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            const _CurrentSeriesLine(),
          ],
        ),
      ),
    );
  }

  /// Завершить и вернуть к списку. Внутри главного экрана (embedded) просто
  /// завершаем: закрытие сделает главный экран.
  void _finish(BuildContext context, TargetViewModel vm) {
    if (vm.session.status == SessionStatus.finished) return;
    vm.finish();
    if (embedded || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Тренировка завершена'))));
    Navigator.of(context).maybePop();
  }

  Widget _buildActionButton(
      BuildContext context, TargetViewModel vm, SessionStatus status) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case SessionStatus.notStarted:
        return Raised3DButton(
            dense: true,
            label: tr('Начать'),
            baseColor: cs.primary,
            onTap: vm.start);
      case SessionStatus.running:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Raised3DButton(
              dense: true,
              label: tr('Пауза'),
              baseColor: cs.secondary,
              onTap: vm.pause),
          const SizedBox(width: 8),
          Raised3DButton(
              dense: true,
              label: tr('Завершить'),
              baseColor: cs.error,
              onTap: () => _finish(context, vm)),
        ]);
      case SessionStatus.paused:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Raised3DButton(
              dense: true,
              label: tr('Продолжить'),
              baseColor: cs.secondary,
              onTap: vm.resume),
          const SizedBox(width: 8),
          Raised3DButton(
              dense: true,
              label: tr('Завершить'),
              baseColor: cs.error,
              onTap: () => _finish(context, vm)),
        ]);
      case SessionStatus.finished:
        return Text(tr('Завершена'),
            style: const TextStyle(fontWeight: FontWeight.bold));
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
/// Индикатор текущей серии и оставшегого времени/выстрелов.
///
/// Показывается только если у упражнения расписана структура — серии
/// разные и стрелку надо знать, в какой он сейчас. У обычного
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
        parts.add(tr('время вышло'));
      } else {
        final m = left.inMinutes.remainder(60).toString().padLeft(2, '0');
        final s = left.inSeconds.remainder(60).toString().padLeft(2, '0');
        parts.add(tr('осталось {p}{m}:{s}',
            {'p': left.inHours > 0 ? '${left.inHours}:' : '', 'm': m, 's': s}));
      }
    } else if (spec.shotCount != null) {
      parts.add(tr('выстрел {p} из {shotCount}',
          {'p': vm.shotsInCurrentSeries + 1, 'shotCount': spec.shotCount}));
    }
    if (!spec.counts) parts.add(tr('без зачёта'));

    // Для режима "по готовности" показываем кнопку перехода к зачёту
    final showCompleteSighting =
        vm.isSightingByReadiness && !vm.sightingManuallyCompleted;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (expired) ...[
            Icon(Icons.timer_off_outlined,
                size: 14, color: theme.colorScheme.error),
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
          if (showCompleteSighting) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => vm.completeSightingByReadiness(),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                tr('К зачёту'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Кнопки действий на самой мишени во время активной правки.
///
/// Тот же `Raised3DButton`, что и у панели просмотра (Выстрел/Править/
/// Фото) — решение пользователя: обе панели живут на одном и том же
/// месте под мишенью и должны выглядеть одной системой, а не парой
/// разных стилей кнопок вперемешку.
class _EditActionBar extends StatelessWidget {
  const _EditActionBar();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final cs = Theme.of(context).colorScheme;
    // Заметка и удаление — только у уже существующего выстрела (id
    // есть, и CommentsThreadSheet/deleteSelected могут к нему
    // обратиться). У черновика новой пробоины id появится только после
    // "Сохранить" — до этого ни комментировать, ни удалять нечего.
    final existingShot = vm.isAddingNew ? null : vm.selectedShot;

    return Material(
      color: cs.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          // До четырёх кнопок сразу (Сохранить/Заметка/Удалить/
          // Отменить) на узком экране в Row с spaceEvenly не помещаются
          // — та же ошибка, что уже была с нижней навигацией. Горизон-
          // тальная прокрутка не даёт им обрезаться или перенестись.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Raised3DButton(
                  dense: true,
                  icon: Icons.check,
                  label: tr('Сохранить'),
                  baseColor: cs.primary,
                  onTap: vm.confirmEdit,
                ),
                if (existingShot != null) ...[
                  const SizedBox(width: 12),
                  Raised3DButton(
                    dense: true,
                    icon: Icons.comment_outlined,
                    label: tr('Заметка'),
                    baseColor: cs.secondary,
                    onTap: () => CommentsThreadSheet.showForShot(
                        context, existingShot.id),
                  ),
                  const SizedBox(width: 12),
                  Raised3DButton(
                    dense: true,
                    icon: Icons.delete_outline,
                    label: tr('Удалить'),
                    baseColor: cs.error,
                    onTap: vm.deleteSelected,
                  ),
                ],
                const SizedBox(width: 12),
                Raised3DButton(
                  dense: true,
                  icon: Icons.close,
                  label: tr('Отменить'),
                  // Не error: эта кнопка ничего не удаляет и не портит,
                  // просто отбрасывает несохранённую правку — сильный
                  // красный здесь спорил бы с настоящим "Удалить" рядом.
                  baseColor: cs.outline,
                  onTap: vm.cancelEditing,
                ),
              ],
            ),
          ),
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

  Future<void> _scanPhoto(BuildContext context, TargetViewModel vm) async {
    setState(() => _scanning = true);
    try {
      final knownHolesMm = [
        for (final s in [...vm.session.shots, ...vm.session.trash])
          PixelPoint(s.xMm, s.yMm),
      ];
      final points = await Navigator.of(context).push<List<PixelPoint>>(
        MaterialPageRoute(
          builder: (_) =>
              PhotoScanScreen(face: vm.face, knownHolesMm: knownHolesMm),
        ),
      );
      if (points == null || points.isEmpty || !context.mounted) return;
      final added = vm.addScannedShots(points);
      if (added < points.length && context.mounted) showPauseAddHint(context);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    if (!vm.canEditShots) return const SizedBox.shrink();

    final hasShots = vm.session.shots.isNotEmpty;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        // Три полноразмерные 3D-кнопки впритык помещаются на широких
        // телефонах, но на узких (360dp и меньше — обычные Android)
        // рискуют обрезаться. Прокрутка — тот же приём, что и в панели
        // правки, вместо угадывания, скольким телефонам хватит места.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (vm.face.hitMiss) ...[
                Raised3DButton(
                  icon: Icons.check_circle_outline,
                  label: tr('Попал'),
                  baseColor: Colors.green.shade700,
                  onTap: () => vm.canAddShotNow
                      ? vm.addHitMiss(true)
                      : showPauseAddHint(context),
                ),
                const SizedBox(width: 16),
                Raised3DButton(
                  icon: Icons.highlight_off,
                  label: tr('Мимо'),
                  baseColor: Colors.red.shade700,
                  onTap: () => vm.canAddShotNow
                      ? vm.addHitMiss(false)
                      : showPauseAddHint(context),
                ),
                const SizedBox(width: 16),
              ] else
                Raised3DButton(
                  icon: Icons.add_circle_outline,
                  label: tr('Выстрел'),
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
              const SizedBox(width: 16),
              Raised3DButton(
                icon: Icons.edit_location_alt_outlined,
                label: tr('Править'),
                baseColor: Theme.of(context).colorScheme.secondary,
                // Правит ВЫБРАННЫЙ выстрел (см. selectedShot) — не всегда
                // последний: выбор мог прийти со свайпа по мишени или из
                // списка выстрелов (shot_list_sheet).
                onTap: hasShots ? vm.beginMoveSelected : null,
              ),
              if (friendlyErrorDevMode) ...[
                const SizedBox(width: 16),
                Raised3DButton(
                  icon: Icons.photo_camera_outlined,
                  label: tr('Фото'),
                  baseColor: Theme.of(context).colorScheme.tertiary,
                  onTap: _scanning ? null : () => _scanPhoto(context, vm),
                ),
              ],
            ],
          ),
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
        height: 25, // ниже ещё на 40% (решение пользователя)
      );
    } else {
      final index = vm.selectedIndex;
      wheel = ShotWheel(
        value: index < 0 ? 0 : index,
        minValue: 0,
        maxValue: total == 0 ? 0 : total - 1,
        enabled: total > 1,
        onChanged: vm.selectIndex,
        height: 25, // ниже ещё на 40% (решение пользователя)
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
