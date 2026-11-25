import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../finals/voice_packs.dart';
import '../finals/announcer.dart';
import '../finals/voice_texts.dart';
import '../voice/voice_control.dart';
import '../voice/voice_grammar.dart';
import '../finals/second_ticker.dart';
import '../finals/round_label.dart';
import '../finals/final_engine.dart';
import '../finals/final_run.dart';
import '../finals/bot.dart';
import '../finals/champions_service.dart';
import '../finals/finals_repository.dart';
import '../finals/plausibility.dart';
import '../services/chat_auth_service.dart';
import '../services/user_profile.dart';
import '../services/supabase_auth_service.dart';
import 'package:provider/provider.dart';
import '../i18n/i18n.dart';
import '../logic/scoring.dart';
import '../models/target_color_scheme.dart';
import '../models/target_face.dart';
import '../painters/target_painter.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/sius_panel.dart';

/// Ход финала. Личный монитор (по умолчанию): мишень спортсмена и список
/// только СВОИХ выстрелов по сериям — мишени соперников с основного экрана
/// убраны (отзыв 23.11 №2: «дать личные выстрелы списком, это личная
/// установка»). Кнопка «Табло» в шапке переключает на экран для зрителей:
/// таблица всех участников с миниатюрами мишеней (отзыв 23.11 №1: «общее
/// табло»). В горизонтальном режиме на широком экране мишень слева, список
/// выстрелов или табло справа (отзыв 23.11 №3: «горизонтальный режим
/// проработать»).
class FinalRunScreen extends StatefulWidget {
  final FinalRunController controller;
  final AppDataStore store;
  final bool custom; // «свой финал» — не публикуется
  const FinalRunScreen({super.key, required this.controller, required this.store, this.custom = false});

  @override
  State<FinalRunScreen> createState() => _FinalRunScreenState();
}

class _FinalRunScreenState extends State<FinalRunScreen> {
  SecondTicker? _timer;
  final List<Offset> _sightingMarks = []; // мм, пристрелка не идёт в зачёт
  bool _saved = false;

  // Отзыв 23.11 №1: вид «Табло» для зрителей вместо бывшей таблицы на свайпе.
  bool _board = false;

  /// Финал не стартует сам: часы пойдут после кнопки «Начать финал».
  bool _started = false;
  late final bool _voice = FinalsPrefs.voice(widget.store.db);
  final _tracker = AnnounceTracker();
  final _phaseVoice = PhaseAnnouncer();

  FinalRunController get c => widget.controller;

  /// Зум мишени, переживающий поворот экрана (отзыв 0ecf7a6c).
  final ValueNotifier<double> _padScale = ValueNotifier<double>(1);

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    // Гибкая озвучка (запрос 17.11): пока идёт финал, фразы диктора
    // досоздаются в фоне — к моменту объявления результата они уже на
    // устройстве, и ждать синтеза посреди серии не приходится. Уже готовые
    // записи не пересоздаются, поэтому повторные финалы почти бесплатны.
    unawaited(VoicePacks.ensureAll(widget.store.db));
    VoiceControl.instance.register(this, {
      VoiceAction.finalReady: (i) {
        if (_started) return tr('Финал уже идёт');
        _begin();
        return tr('Начинаем');
      },
    });
  }

  void _onChange() {
    if (!mounted) return;
    if (c.phase == RunPhase.finished && !_saved) {
      _saved = true;
      _timer?.cancel();
      final rec = c.toRecord()..['custom'] = widget.custom;
      FinalsRepository(widget.store.db).save(rec);
      Future.microtask(() {
        if (mounted) {
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => FinalResultScreen(record: rec)));
        }
      });
      return;
    }
    if (_voice && _started) {
      final cmd = _phaseVoice.update(c.phase.name, secondsLeft: c.secondsLeft, announcing: c.announcing);
      if (cmd != null) FinalsAnnouncer.say(widget.store.db, cmd, refs: _phaseVoice.lastRef == null ? null : [_phaseVoice.lastRef!]);
      final text = _tracker.update(
        [for (final r in c.live) AnnounceRow(r.c.name, r.total, r.c.active, isMe: r.c.id == c.userId)],
        announcing: c.announcing,
      );
      if (text != null) FinalsAnnouncer.say(widget.store.db, text, refs: _tracker.lastRefs);
    }
    setState(() {});
  }

  @override
  void dispose() {
    VoiceControl.instance.unregister(this);
    FinalsAnnouncer.stop();
    _timer?.cancel();
    _padScale.dispose();
    c.removeListener(_onChange);
    super.dispose();
  }

  /// «Готов»: только теперь идёт отсчёт — начинается пристрелка (5 минут), звучит «Пристрелка», затем команды.
  void _begin() {
    if (_started) return;
    // Проба до «Готов» не идёт в пристрелку (отзыв ac4c4f27).
    c.clearPreparationShots();
    setState(() => _started = true);
    _timer = SecondTicker(c.tick)..start();
  }

  String _banner() {
    if (!_started) return tr('Подготовка: время не идёт');
    switch (c.phase) {
      case RunPhase.sighting:
        return tr('Подготовка и пристрелка');
      case RunPhase.loading:
        return c.announcing ? tr('Комментарий диктора') : tr('Заряжай… старт через {n} с', {'n': c.secondsLeft});
      case RunPhase.finished:
        return tr('Финал окончен');
      case RunPhase.grace:
        return c.awaitingResult ? tr('Укажите результат выстрела') : tr('Стоп! Отметьте выстрел');
      case RunPhase.shooting:
        final l = c.roundLabel;
        if (l == 'shootoff') return tr('Перестрелка');
        if (l == 'open') return tr('С колена и лёжа: 20 выстрелов');
        return finalRoundLabel(c.format.id, l);
    }
  }

  String _time() {
    if (!_started) return '';
    final s = switch (c.phase) {
      RunPhase.shooting => (c.roundLimit - c.roundSeconds).clamp(0, 9999),
      _ => c.secondsLeft,
    };
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Общее время упражнения для панели «как SIUS»: с начала «Готов»,
  /// включая пристрелку (циферблат финала идёт и там — только команды нет).
  String _totalTime() {
    if (!_started) return '0:00';
    final sightElapsed =
        c.phase == RunPhase.sighting ? c.format.sightingSeconds - c.secondsLeft : 0;
    final s = (c.clock + sightElapsed).clamp(0, 9999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Номер серии (с 1) по сквозному номеру выстрела [no] (с 1); 0 —
  /// выстрел сверх всех серий формата (одиночные на выбывание). Границы —
  /// те же, что в списке выстрелов ([_FinalShotList]).
  int _seriesOfShotNo(int no) {
    final limits = c.format.seriesShots;
    var s = 1;
    var acc = 0;
    while (s <= limits.length && acc + limits[s - 1] <= no - 1) {
      acc += limits[s - 1];
      s++;
    }
    return s <= limits.length ? s : 0;
  }

  /// Панель «как SIUS» с живыми данными личного монитора (владелец 24.11):
  /// список своих выстрелов, суммы серий, последний выстрел крупно, время и
  /// обратный отсчёт раунда. В пристрелке — режим «последние 5» и MPI.
  Widget _siusPanel() {
    final limits = c.format.seriesShots;
    final rows = <SiusShotRow>[];
    if (c.phase == RunPhase.sighting) {
      // Пристрелка (в зачёт не идёт): строки «P» и подсчёт последних пяти.
      for (var i = 0; i < _sightingMarks.length; i++) {
        final m = _sightingMarks[i];
        rows.add(SiusShotRow(
          number: i + 1,
          series: 1,
          score: scoreForPoint(m.dx, m.dy, c.face),
          point: m,
          sighting: true,
        ));
      }
    } else {
      // Зачётные выстрелы движка плюс отмеченные в текущем раунде — тот же
      // набор, что в списке личного монитора, чтобы цифры совпадали.
      final closed = [for (final s in c.shots) if (s.who == c.userId && !s.shootOff) s];
      var no = 0;
      for (final s in closed) {
        no = s.index + 1;
        rows.add(SiusShotRow(
          number: no,
          series: _seriesOfShotNo(no),
          score: s.score,
          point: Offset(s.x, s.y),
        ));
      }
      for (var i = 0; i < c.staged.length; i++) {
        final s = c.staged[i];
        rows.add(SiusShotRow(
          number: closed.length + i + 1,
          series: _seriesOfShotNo(closed.length + i + 1),
          score: scoreForPoint(s.x, s.y, c.face),
          point: Offset(s.x, s.y),
        ));
      }
    }
    // Подпись серии только в серийных раундах: одиночные и перестрелка вне серий.
    final seriesLabel =
        !c.inShootOff && c.roundIndex < limits.length && c.roundIndex >= 0 && c.phase != RunPhase.sighting
            ? tr('Серия {n} из {m}', {'n': c.roundIndex + 1, 'm': limits.length})
            : null;
    final countdown = _time();
    return SiusPanel(
      face: c.face,
      shots: rows,
      title: c.face.name,
      seriesLabel: seriesLabel,
      timeText: _totalTime(),
      countdownText: countdown.isEmpty ? null : countdown,
      seriesShots: limits,
      lastFiveMode: c.phase == RunPhase.sighting,
    );
  }

  bool get _canPlace => c.phase == RunPhase.sighting || c.userCanShoot;

  void _onShot(Offset mm) {
    if (c.phase == RunPhase.sighting) {
      setState(() => _sightingMarks.add(mm));
    } else {
      c.submitUserShot(mm.dx, mm.dy);
    }
  }

  void _undo() {
    if (c.phase == RunPhase.sighting) {
      if (_sightingMarks.isNotEmpty) setState(() => _sightingMarks.removeLast());
    } else {
      c.undoUserShot();
    }
  }

  List<Offset> get _myMarks =>
      c.phase == RunPhase.sighting ? _sightingMarks : [for (final s in c.staged) Offset(s.x, s.y)];

  Future<bool> _confirmLeave() async {
    c.pause();
    final leave = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Выйти из финала?')),
        content: Text(tr('Финал будет прекращён, результаты не сохранятся.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Остаться'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Выйти'))),
        ],
      ),
    );
    if (leave != true) c.resume();
    return leave == true;
  }

  /// Покинуть финал без сохранения результата.
  Future<void> _leave() async {
    if (await _confirmLeave()) {
      _saved = true;
      _timer?.cancel();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _leave();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        // Отзыв 23fb17fd: в горизонтали шапку убираем — она отнимает высоту
        // у мишени; управление переезжает в строку действий внизу.
        appBar: MediaQuery.orientationOf(context) == Orientation.landscape
            ? null
            : GlassHeader(
          // «Назад»: с табло — на личный монитор, оттуда — выход из финала.
          leading: IconButton(
            tooltip: tr('Назад'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_board) {
                setState(() => _board = false);
              } else {
                _leave();
              }
            },
          ),
          title: Row(children: [
            Expanded(
                child: Text(_banner(),
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            Text(_time(),
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          actions: [
            // Отзыв 23.11 №1/№2: переключатель «личный монитор / табло для зрителей»
            // вместо бывшей таблицы на свайпе.
            IconButton(
              tooltip: _board ? tr('Мой экран') : tr('Табло зрителей'),
              icon: Icon(_board ? Icons.person : Icons.tv),
              onPressed: () => setState(() => _board = !_board),
            ),
            // Удержание паузы — долгая (судьинская) пауза до «Продолжить»:
            // отзывы 7c58a3e2 и 4013c8db (в т.ч. при исчерпанном лимите).
            GestureDetector(
              onLongPress: c.paused ? null : () => c.pause(long: true),
              child: IconButton(
                tooltip: c.paused
                    ? tr('Продолжить')
                    : tr('Пауза (удержать — долгая пауза)'),
                icon: Icon(c.paused
                    ? Icons.play_arrow
                    : (c.longPaused ? Icons.pause_circle : Icons.pause)),
                onPressed: c.paused ? c.resume : c.pause,
              ),
            ),
            IconButton(
              tooltip: tr('Покинуть финал'),
              icon: const Icon(Icons.logout),
              onPressed: _leave,
            ),
          ],
        ),
        // Отзыв 23.11 №1/№2: личный монитор по умолчанию, табло — по кнопке в шапке.
        // В горизонтальном режиме на широком экране (отзыв 23.11 №3) мишень
        // остаётся слева, а справа — список выстрелов либо табло.
        body: LayoutBuilder(builder: (ctx, box) {
          final mq = MediaQuery.of(ctx);
          final wide = mq.orientation == Orientation.landscape && box.maxWidth >= 700;
          return _body(ctx, wide: wide);
        }),
      ),
    );
  }

  /// Одна мишень спортсмена со своими наложениями (подпись пристрелки, пауза).
  Widget _padArea(BuildContext context) {
    final theme = Theme.of(context);
    final sighting = c.phase == RunPhase.sighting;
    final marks = _myMarks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Stack(children: [
        Positioned.fill(
          child: ShotPad(
            face: c.face,
            marks: marks,
            enabled: _canPlace && !c.paused,
            // Мишень прикована центром: двумя пальцами не сдвинуть, меняется
            // только масштаб (отзыв 18.11: «сделать как в тренировках»).
            lockCenter: true,
            // Лупа при удержании вела себя одинаково; PAGE больше нет, поэтому
            // свайп-блокировка не нужна — слушатель остаётся, но пустой.
            onHold: (_) {},
            onShot: _onShot,
            sighting: sighting,
            scaleNotifier: _padScale,
          ),
        ),
        if (sighting)
          // Только подпись: сам уголок пристрелки теперь рисует TargetPainter
          // (SightingCorner) прямо по углу бланка — раньше здесь висела вторая
          // метка, и на финалах их было две (отзыв владельца 22.11).
          Positioned(
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(tr('Пристрелка'), style: const TextStyle(fontSize: 11, color: Colors.white)),
              ),
            ),
          ),
        if (c.paused)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(tr('Пауза'), style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white)),
                  // Остаток времени паузы и сообщение о лимитах (ISSF 2026: 2 паузы по 120 с).
                  if (c.pauseSecondsLeft != null)
                    Text(tr('До автопродолжения: {n} с', {'n': c.pauseSecondsLeft}),
                        style: theme.textTheme.titleSmall?.copyWith(color: Colors.white)),
                  if (c.pauseNotice != null)
                    Text(c.pauseNotice!, textAlign: TextAlign.center, style: theme.textTheme.titleSmall?.copyWith(color: Colors.white)),
                ]),
              ),
            ),
          ),
        // Пауза отклонена (лимит пауз исчерпан): показываем, пока время идёт.
        if (!c.paused && c.pauseNotice != null)
          Positioned(
            bottom: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
                child: Text(c.pauseNotice!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white)),
              ),
            ),
          ),
      ]),
    );
  }

  /// Строка статуса и кнопки («Готов», «Промах», «Назад» и т. д.).
  /// В широкой раскладке кнопки переносятся [Wrap'ом] — ширины не хватает.
  Widget _actionRow(BuildContext context, {required bool wide}) {
    final sighting = c.phase == RunPhase.sighting;
    final marks = _myMarks;
    final status = Text(
      sighting
          ? (_started
              ? tr('Пристрелка: выстрелы не идут в зачёт')
              : tr('Освойтесь с мишенью — выстрелы не идут в зачёт. Время и команды начнутся после «Готов»'))
          : c.userCanShoot
              ? tr('Осталось выстрелов: {n}', {'n': c.userShotsLeft})
              // Значения выстрелов переехали в список на мониторе (отзыв 23.11 №2),
              // поэтому дубль строкой больше не показываем.
              : (c.user.active ? tr('Ждите команды') : tr('Вы выбыли — боты продолжают')),
      style: Theme.of(context).textTheme.bodyMedium,
      maxLines: wide ? 2 : 3,
      overflow: TextOverflow.ellipsis,
    );
    final buttons = <Widget>[
      if (sighting && !_started) FilledButton(onPressed: _begin, child: Text(tr('Готов'))),
      if (sighting && _started) TextButton(onPressed: c.skipSighting, child: Text(tr('Пропустить пристрелку'))),
      if (!c.user.active && c.phase != RunPhase.finished)
        TextButton(onPressed: c.fastForward, child: Text(tr('Завершить результат'))),
      if (c.awaitingResult) FilledButton.tonal(onPressed: () => c.markMiss(c.userId), child: Text(tr('Промах'))),
      TextButton.icon(
        onPressed: marks.isEmpty ? null : _undo,
        icon: const Icon(Icons.undo),
        label: Text(tr('Назад')),
      ),
      // В горизонтали шапки нет: переключатель табло, пауза и выход живут
      // здесь, левым блоком (отзывы 23fb17fd, 66ae8063).
      if (wide) ...[
        IconButton(
          tooltip: _board ? tr('Мой экран') : tr('Табло зрителей'),
          icon: Icon(_board ? Icons.person : Icons.tv),
          onPressed: () => setState(() => _board = !_board),
        ),
        GestureDetector(
          onLongPress: c.paused ? null : () => c.pause(long: true),
          child: IconButton(
            tooltip: c.paused ? tr('Продолжить') : tr('Пауза'),
            icon: Icon(c.paused ? Icons.play_arrow : Icons.pause),
            onPressed: c.paused ? c.resume : c.pause,
          ),
        ),
        IconButton(
          tooltip: tr('Покинуть финал'),
          icon: const Icon(Icons.logout),
          onPressed: _leave,
        ),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      // Wrap вместо Row: на любой ширине кнопки переезжают на новую строку,
      // а не вылезают за экран (отзыв 23.11 №3, «переполнений быть не должно»).
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          SizedBox(width: wide ? 260 : double.infinity, child: status),
          ...buttons,
        ],
      ),
    );
  }

  Widget _body(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    // Отзыв 25.11 (4284f0c9, ca854964): между шапкой и мишенью был большой
    // пустой отступ — тело и так начинается под статус-баром, а шапка
    // стеклянная и висит поверх содержимого. Оставляем только дыхание 8 px.
    final top = MediaQuery.paddingOf(context).top + 8;
    final side = _board ? _BoardView(c: c) : _FinalShotList(c: c);
    if (wide) {
      // Отзыв 23.11 №3: мишень слева, список выстрелов/табло справа.
      // Владелец 24.11 («как SIUS»): на широком экране вместо плоского
      // списка — SiusPanel с живыми данными; табло остаётся по кнопке в
      // шапке. Портретная раскладка не меняется.
      return Column(children: [
        SizedBox(height: top),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 6, child: _padArea(context)),
            Expanded(
              flex: 4,
              child: _board
                  ? side
                  : Padding(
                      // Те же отступы, что у мишени рядом.
                      padding: const EdgeInsets.fromLTRB(0, 2, 8, 2),
                      child: _siusPanel(),
                    ),
            ),
          ]),
        ),
        // Отзыв f4362cb2: в горизонтали тоже нужна стрелка «удалить выстрел»
        // (у нас это «Назад» — отменяет последнюю пробоину) и прочие кнопки.
        _actionRow(context, wide: true),
      ]);
    }
    if (_board) {
      // Табло вместо всего экрана: это отдельный вид для зрителей (отзыв №1).
      return Column(children: [SizedBox(height: top), Expanded(child: side)]);
    }
    // Личный монитор (портрет): мишень, затем список своих выстрелов.
    return Column(children: [
      SizedBox(height: top),
      Text(c.user.name, style: theme.textTheme.titleSmall),
      Expanded(flex: 6, child: _padArea(context)),
      _actionRow(context, wide: false),
      Expanded(flex: 4, child: side),
    ]);
  }

}

/// Мишень спортсмена. Удержание пальца показывает над пальцем окошко-лупу с
/// увеличенной мишенью и пробоиной (как при выделении текста): палец двигается —
/// пробоина смещается; отпускание сохраняет выстрел.
class ShotPad extends StatefulWidget {
  final TargetFace face;
  final List<Offset> marks;
  final bool enabled;
  final ValueChanged<bool> onHold;
  final ValueChanged<Offset> onShot;

  /// Своя схема цветов мишени (режим концентрации); по умолчанию — обычная.
  final TargetColorScheme? colors;

  /// Мишень при зуме всегда по центру (режим концентрации): сдвиг двумя пальцами отключён.
  final bool lockCenter;

  /// Идёт пристрелка: на бумаге рисуется загнутый уголок, как на бланке.
  final bool sighting;
  /// Масштаб мишени живёт снаружи: при повороте экрана дерево перестраивается
  /// (широкая/узкая раскладка), состояние виджета уничтожается, а выбранный
  /// зум должен остаться (отзыв 0ecf7a6c).
  final ValueNotifier<double>? scaleNotifier;
  const ShotPad({required this.face, required this.marks, required this.enabled, required this.onHold, required this.onShot, this.colors, this.lockCenter = false, this.sighting = false, this.scaleNotifier});

  @override
  State<ShotPad> createState() => _ShotPadState();
}

class _ShotPadState extends State<ShotPad> {
  @override
  void initState() {
    super.initState();
    // Зум, выбранный до поворота экрана, восстанавливается из notifier.
    _scale = widget.scaleNotifier?.value ?? 1;
  }
  /// Увеличение лупы: шаг десятой доли занимает ~4,5 пикселя (мягче, чем
  /// раньше: сильное увеличение «убегало» из-под пальца).
  double get _zoom => (4.5 * widget.face.faceRadiusMm / (_stepMm * _loupe / 2)).clamp(3.0, 24.0);
  double get _stepMm {
    final st = widget.face.decimalStepMm;
    return st > 0 ? st : 1.0;
  }
  static const double _loupe = 190; // диаметр лупы, px
  static const double _gap = 125; // от пальца до центра лупы
  Offset? _finger; // px

  /// Зум мишени: масштаб (1…6) и сдвиг центра в пикселях. Один палец — лупа и выстрел; второй палец —
  /// лупа пропадает, щипок меняет масштаб; выстрела нет, пока не отпустят все пальцы и не будет нового одиночного касания.
  double _scale = 1;
  Offset _pan = Offset.zero;
  /// Для распознавания двойного тапа (сброс зума и центрирование мишени).
  DateTime? _lastTapAt;
  Offset? _lastTapPos;
  bool _suppressShot = false;
  final Map<int, Offset> _pointers = {};
  bool _zoomMode = false;
  double _zStartDist = 1, _zStartScale = 1;
  Offset _zStartPan = Offset.zero, _zStartFocal = Offset.zero;
  static const double _maxScale = 6;

  double _k(Size s) => s.shortestSide / 2 / widget.face.faceRadiusMm;

  /// Для тестов: текущий масштаб.
  @visibleForTesting
  double get debugScale => _scale;

  Offset _toMm(Offset p, Size s) {
    final k = _k(s) * _scale;
    return Offset((p.dx - s.width / 2 - _pan.dx) / k, -(p.dy - s.height / 2 - _pan.dy) / k);
  }

  Offset _clampPan(Offset p, Size s) {
    final lim = (_scale - 1) * s.shortestSide / 2;
    return Offset(p.dx.clamp(-lim, lim).toDouble(), p.dy.clamp(-lim, lim).toDouble());
  }

  void _setScale(double v, Size s) {
    setState(() {
      _scale = v.clamp(1.0, _maxScale).toDouble();
      widget.scaleNotifier?.value = _scale;
      _pan = _clampPan(_pan, s);
    });
  }

  void _pointerDown(PointerDownEvent e, Size s) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      // Появился второй палец: лупа пропадает, включается зум.
      // Заодно забываем прошлый тап — иначе первый одиночный тап после щипка
      // мог быть принят за двойной и съесть выстрел.
      _lastTapAt = null;
      _lastTapPos = null;
      final pts = _pointers.values.take(2).toList();
      _zoomMode = true;
      _zStartDist = math.max((pts[0] - pts[1]).distance, 1);
      _zStartScale = _scale;
      _zStartPan = _pan;
      _zStartFocal = (pts[0] + pts[1]) / 2;
      if (_finger != null) setState(() => _finger = null);
      widget.onHold(true);
      return;
    }
    if (_zoomMode) return; // остался один палец после зума: лупа не включается
    _down(e.localPosition, s);
  }

  void _pointerMove(PointerMoveEvent e, Size s) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_zoomMode) {
      if (_pointers.length >= 2) {
        final pts = _pointers.values.take(2).toList();
        final dist = math.max((pts[0] - pts[1]).distance, 1);
        final focal = (pts[0] + pts[1]) / 2;
        final ns = (_zStartScale * dist / _zStartDist).clamp(1.0, _maxScale).toDouble();
        // Масштаб — относительно центра мишени (она остаётся по центру), а двумя пальцами её можно
        // подвинуть: сдвиг равен перемещению середины между пальцами. Панорама НЕ умножается на
        // масштаб — именно поэтому в тренировке мишень «само центрируется», а здесь уезжала
        // (отзыв 17.11 17:50 «надо скопировать механику с тренировок»).
        setState(() {
          _scale = ns;
          _pan = widget.lockCenter ? Offset.zero : _clampPan(_zStartPan + (focal - _zStartFocal), s);
        });
      }
      return;
    }
    if (_finger != null) setState(() => _finger = e.localPosition);
  }

  void _pointerUp(PointerEvent e, Size s, {required bool cancel}) {
    _pointers.remove(e.pointer);
    if (_zoomMode) {
      if (_pointers.isEmpty) {
        _zoomMode = false; // всё отпущено: выстрела нет, лупа — только на новое одиночное касание
        widget.onHold(false);
      }
      return;
    }
    if (cancel) {
      setState(() => _finger = null);
      widget.onHold(false);
    } else {
      _up(s);
    }
  }

  void _down(Offset f, Size s) {
    if (!widget.enabled) return;
    // Двойной тап — вернуть мишень в центр и сбросить зум, как в тренировке
    // (отзыв 17.11 «мишень не само центрируется»). Распознаём сами, без
    // GestureDetector: его таймеры ломают widget-тесты и конфликтуют с Listener.
    final now = DateTime.now();
    final prevAt = _lastTapAt;
    final prevPos = _lastTapPos;
    if (prevAt != null &&
        prevPos != null &&
        (_scale > 1.01 || _pan != Offset.zero) &&
        now.difference(prevAt) < const Duration(milliseconds: 400) &&
        (f - prevPos).distance < 48) {
      _lastTapAt = null;
      _lastTapPos = null;
      _suppressShot = true;
      setState(() {
        _scale = 1;
        widget.scaleNotifier?.value = 1;
        _pan = Offset.zero;
      });
      return;
    }
    _lastTapAt = now;
    _lastTapPos = f;
    setState(() => _finger = f);
    widget.onHold(true);
  }

  void _up(Size s) {
    if (_suppressShot) {
      // Это был второй тап двойного — выстрела нет.
      _suppressShot = false;
      setState(() => _finger = null);
      widget.onHold(false);
      return;
    }
    final f = _finger;
    if (f == null) return;
    final mm = _toMm(f, s);
    setState(() => _finger = null);
    widget.onHold(false);
    widget.onShot(mm);
  }

  /// Лупа над пальцем в координатах всего экрана (рисуется в слое Overlay поверх остальных окон).
  Widget? _buildLoupe(Offset? f, Size size, {required Offset origin, required Size screen, required double safeTop}) {
    Widget? loupe;
    if (f != null) {
        final mm = _toMm(f, size);
        final score = formatScore(scoreForPoint(mm.dx, mm.dy, widget.face), widget.face);
        // Лупа ВСЕГДА над пальцем и поверх всех окон (в верхнем слое экрана), не прыгает вниз:
        // у самого верха экрана просто упирается в его край.
        final g = origin + f;
        final cx = g.dx.clamp(_loupe / 2, screen.width - _loupe / 2);
        final cy = math.max(g.dy - _gap, safeTop + _loupe / 2);
        final kz = _loupe / 2 * _zoom / widget.face.faceRadiusMm;
        final pan = Offset(-mm.dx * kz, mm.dy * kz); // точка выстрела — в центре лупы
        final lc = Offset(_loupe / 2, _loupe / 2) + pan;
        loupe = Positioned(
          left: cx - _loupe / 2,
          top: cy - _loupe / 2,
          width: _loupe,
          height: _loupe,
          child: IgnorePointer(
            child: Stack(clipBehavior: Clip.none, children: [
              DecoratedBox(
                // Тень лупы — объём вместо плоской наклейки.
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 22, spreadRadius: 1, offset: const Offset(0, 10)),
                  ],
                ),
                child: DecoratedBox(
                // Рамка рисуется ПОВЕРХ (foreground): иначе она сужает область
                // и центр мишени смещается на её толщину относительно перекрестия.
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 4),
                ),
                child: ClipOval(
                  child: Stack(children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: TargetPainter(
                          face: widget.face,
                          colors: widget.colors ?? TargetColorScheme.defaultScheme,
                          visibleShots: const [],
                          selectedShot: null,
                          currentSeriesNo: 1,
                          zoom: _zoom,
                          pan: pan,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: ShotMarkerPainter(widget.marks,
                            k: kz, center: lc, finger: Offset(_loupe / 2, _loupe / 2), holeR: 2.25 * kz, lens: true),
                      ),
                    ),
                    // Блик и виньетка стекла.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(-0.45, -0.55),
                            radius: 1.0,
                            colors: [Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0.0), Colors.black.withValues(alpha: 0.18)],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: -30,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                    child: Text(score, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ]),
          ),
        );
    }
    return loupe;
  }

  OverlayEntry? _entry;
  Size _padSize = Size.zero;

  /// Показывает/прячет слой с лупой в зависимости от того, лежит ли палец на мишени.
  void _syncOverlay() {
    if (!mounted) return;
    if (_finger != null && _entry == null) {
      _entry = OverlayEntry(builder: (ctx) {
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.attached) return const SizedBox.shrink();
        final mq = MediaQuery.of(ctx);
        final loupe = _buildLoupe(_finger, _padSize, origin: box.localToGlobal(Offset.zero), screen: mq.size, safeTop: mq.padding.top);
        return Positioned.fill(child: IgnorePointer(child: Stack(clipBehavior: Clip.none, children: [if (loupe != null) loupe])));
      });
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    } else if (_finger == null && _entry != null) {
      _entry!.remove();
      _entry = null;
    } else {
      _entry?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final k = _k(size);
      final f = _finger;
      _padSize = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncOverlay());
      final center = Offset(size.width / 2, size.height / 2) + _pan;
      return Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          // Двойной тап распознаём сами в Listenere (см. _pointerDown/_pointerUp):
          // GestureDetector оставляет таймер и ломает widget-тесты.
          child: Listener(
            onPointerDown: (e) => _pointerDown(e, size),
            onPointerMove: (e) => _pointerMove(e, size),
            onPointerUp: (e) => _pointerUp(e, size, cancel: false),
            onPointerCancel: (e) => _pointerUp(e, size, cancel: true),
            child: ClipRect(
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: TargetPainter(
                      face: widget.face,
                      colors: widget.colors ?? TargetColorScheme.defaultScheme,
                      visibleShots: const [],
                      selectedShot: null,
                      currentSeriesNo: 1,
                      zoom: _scale,
                      pan: _pan,
                      sighting: widget.sighting,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: ShotMarkerPainter(widget.marks,
                        k: k * _scale,
                        center: center,
                        finger: f,
                        holeR: math.max(3.0, 2.25 * k * _scale),
                        labels: [for (final m in widget.marks) formatScore(scoreForPoint(m.dx, m.dy, widget.face), widget.face)]),
                  ),
                ),
              ]),
            ),
          ),
        ),
        // Кнопки зума на всех устройствах (щипок двумя пальцами тоже работает).
        Positioned(
          left: 2,
          bottom: 2,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              tooltip: tr('Приблизить'),
              onPressed: _scale >= _maxScale ? null : () => _setScale(_scale + 1, size),
              icon: const Icon(Icons.add),
            ),
            IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              tooltip: tr('Отдалить'),
              onPressed: _scale <= 1 ? null : () => _setScale(_scale - 1, size),
              icon: const Icon(Icons.remove),
            ),
          ]),
        ),
        // В вебе справа вертикальный ползунок зума; на телефоне зум — щипком двумя пальцами.
        if (kIsWeb)
        Positioned(
          right: 0,
          top: size.height * 0.15,
          bottom: size.height * 0.15,
          width: 36,
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9)),
              child: Slider(min: 1, max: _maxScale, value: _scale, onChanged: (v) => _setScale(v, size)),
            ),
          ),
        ),
      ]);
    });
  }
}

/// Личный монитор: список СВОИХ выстрелов списком (отзыв 23.11 №2 — мишени
/// соперников с основного экрана убраны): «№ · значение» со стрелкой
/// направления, заголовок «Серия N» с суммой и «Итого» в конце — как на
/// экране тренировки. Перестрелочные выстрелы не показываются: в зачёт они
/// не идут.
class _FinalShotList extends StatelessWidget {
  final FinalRunController c;
  const _FinalShotList({required this.c});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Зачётные выстрелы, уже ушедшие в движок, плюс отмеченные в текущем
    // раунде (в списке видны сразу, как только поставлены).
    final closed = [for (final s in c.shots) if (s.who == c.userId && !s.shootOff) s];
    final rows = <({int no, double score, Offset pt})>[
      for (final s in closed) (no: s.index + 1, score: s.score, pt: Offset(s.x, s.y)),
      for (var i = 0; i < c.staged.length; i++)
        (
          no: closed.length + i + 1,
          score: scoreForPoint(c.staged[i].x, c.staged[i].y, c.face),
          pt: Offset(c.staged[i].x, c.staged[i].y),
        ),
    ];
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Text(
          tr('Зачётных выстрелов пока нет'),
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }

    // Группировка по сериям: границы серий берём из формата финала; выстрелы
    // сверх всех серий (одиночные на выбывание) — в общую группу в конце.
    final limits = c.format.seriesShots;
    final groups = <int, List<({int no, double score, Offset pt})>>{};
    for (final r in rows) {
      var s = 0;
      var acc = 0;
      while (s < limits.length && acc + limits[s] <= r.no - 1) {
        acc += limits[s];
        s++;
      }
      groups.putIfAbsent(s < limits.length ? s + 1 : -1, () => []).add(r);
    }
    final keys = groups.keys.map((k) => (k, k < 0 ? 1 << 30 : k)).toList()..sort((a, b) => a.$2.compareTo(b.$2));

    var totalTenths = 0.0;
    var totalWhole = 0;
    final blocks = <Widget>[];
    for (final (key, _) in keys) {
      final list = groups[key]!;
      var sum = 0.0;
      var whole = 0;
      for (final r in list) {
        sum += r.score;
        whole += r.score.floor();
      }
      totalTenths += sum;
      totalWhole += whole;
      blocks.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2, left: 12, right: 12),
        child: Row(children: [
          Text(
            key < 0 ? tr('Одиночные') : tr('Серия {n}', {'n': key}),
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Text(
            tr('Сумма {tenths} / {whole}', {'tenths': sum.toStringAsFixed(1), 'whole': '$whole'}),
            style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ]),
      ));
      for (final r in list) {
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
          child: Row(children: [
            SizedBox(width: 28, child: Text('${r.no}', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
            SizedBox(
              width: 56,
              child: Text(
                formatScore(r.score, c.face),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            // Стрелка направления от центра: та же логика, что на тренировке
            // (отзыв 23.11 №11 — ось Y вверх, положительный X вправо).
            Builder(builder: (ctx) {
              final rDist = math.sqrt(r.pt.dx * r.pt.dx + r.pt.dy * r.pt.dy);
              if (rDist < 0.15) return const SizedBox(width: 16);
              return Transform.rotate(
                angle: math.atan2(r.pt.dx, r.pt.dy), // 0 — вверх, по часовой
                child: Icon(Icons.arrow_upward_rounded, size: 14, color: cs.onSurfaceVariant),
              );
            }),
          ]),
        ));
      }
    }
    blocks.add(Padding(
      padding: const EdgeInsets.only(top: 10, left: 12, right: 12),
      child: Row(children: [
        Text(tr('Итого'), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(
          '${totalTenths.toStringAsFixed(1)} / $totalWhole',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ]),
    ));
    return ListView(children: blocks);
  }
}

/// Табло для зрителей (отзыв 23.11 №1 «общее табло»): таблица всех участников
/// — место, имя, отметка бота, результат в десятых и целых — и рядом миниатюра
/// мишени каждого. Данные берутся из живой таблицы контроллера, поэтому
/// обновляется само после каждого выстрела (экран пересобирается в _onChange).
class _BoardView extends StatelessWidget {
  final FinalRunController c;
  const _BoardView({required this.c});

  @override
  Widget build(BuildContext context) {
    final rows = c.live;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      itemCount: rows.length,
      itemBuilder: (ctx, i) => _BoardRow(c: c, row: rows[i], index: i),
    );
  }
}

/// Строка табло: место, имя (+ бейдж бота), сумма «десятые / целые»,
/// миниатюра мишени — если по этому участнику есть пробоины.
class _BoardRow extends StatelessWidget {
  final FinalRunController c;
  final LiveRow row;
  final int index;
  const _BoardRow({required this.c, required this.row, required this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isBot = !c.humans.contains(row.c.id);
    // Пробоины участника: зачётные + отмеченные в текущем раунде (те же, что
    // идут в живую таблицу); перестрелочные — бледными призраками.
    final pts = [for (final s in c.shots) if (s.who == row.c.id && !s.shootOff) Offset(s.x, s.y)];
    if (c.humans.contains(row.c.id) && row.c.active) {
      for (final st in c.stagedOf(row.c.id)) {
        pts.add(Offset(st.x, st.y));
      }
    }
    final ghosts = [
      for (final s in c.shots)
        if (s.who == row.c.id && s.shootOff) Offset(s.x, s.y),
    ];
    // Целые — сумма целых частей выстрелов (как в протоколе финала).
    final whole = row.shots.fold<int>(0, (a, b) => a + b.floor());
    return Opacity(
      opacity: row.c.active ? 1 : 0.5,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: row.c.isUser ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          // Место и, после жеребьёвки, стартовый номер (ISSF 2026 / владелец 24.11):
          // номер — под местом, чтобы строка не разъезжалась на узком экране.
          SizedBox(
            width: 34,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${row.c.place ?? (index + 1)}',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              if (c.startNumbers[row.c.id] != null)
                Text('№${c.startNumbers[row.c.id]}',
                    style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(row.c.name,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                // Отметка бота: на табло зритель должен сразу видеть, кто живой участник.
                if (isBot) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(tr('Бот'), style: theme.textTheme.labelSmall),
                  ),
                  // Чем занят бот больше не показываем (отзыв b513adc5:
                  // «перезарядка, целится и все остальные действия ботов
                  // стоит убрать, от них нет смысла») — только метка «Бот».
                ],
              ]),
              // Места идут по сумме на контрольной точке (ISSF 2026); средний
              // выстрел — только подпись.
              if (row.shots.isNotEmpty)
                Text(
                  '${tr('ср')} ${row.avg.toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
            ]),
          ),
          Text(
            '${row.total.toStringAsFixed(1)} / $whole',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          // Миниатюра мишени — только если есть пробоины (посадочных
          // пустых квадратов на табло быть не должно).
          if (pts.isNotEmpty) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 56,
              height: 56,
              child: _MiniTarget(c: c, points: pts, ghosts: ghosts),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Миниатюра мишени участника для табло: масштаб подбирается так, чтобы все
/// пробоины уместись видимыми (как было на карточках соперников).
class _MiniTarget extends StatelessWidget {
  final FinalRunController c;
  final List<Offset> points; // мм
  final List<Offset> ghosts; // перестрелочные, бледно
  const _MiniTarget({required this.c, required this.points, this.ghosts = const []});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      var far = 0.0;
      for (final p in points) {
        far = math.max(far, math.sqrt(p.dx * p.dx + p.dy * p.dy));
      }
      // Мишень приближается к центру, пока пробоины умещаются; сильный промах
      // уменьшает зум, чтобы пробоина осталась видна.
      final zoom = math.min(2.5, c.face.faceRadiusMm * 0.85 / math.max(far, 1.0)).clamp(1.0, 2.5).toDouble();
      final k = box.biggest.shortestSide / 2 * zoom / c.face.faceRadiusMm;
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: CustomPaint(
              painter: TargetPainter(
                face: c.face,
                colors: TargetColorScheme.defaultScheme,
                visibleShots: const [],
                selectedShot: null,
                currentSeriesNo: 1,
                zoom: zoom,
                denseLabels: true,
                sighting: c.phase == RunPhase.sighting,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: ShotMarkerPainter(
                points.isEmpty ? const [] : [points.last],
                ghosts: [...ghosts, for (final p in points.take(math.max(0, points.length - 1))) p],
                k: k,
                center: Offset(box.maxWidth / 2, box.maxHeight / 2),
              ),
            ),
          ),
        ]),
      );
    });
  }
}

class ShotMarkerPainter extends CustomPainter {
  final List<Offset> placed; // мм
  final double k; // px на мм
  final Offset center;
  final Offset? finger; // px: где сейчас пробоина-кандидат
  final double holeR; // радиус кандидата, px
  /// Подписи к пробоинам (значение выстрела), по порядку [placed].
  final List<String>? labels;

  /// Внутри лупы: тонкое перекрестие и кольцо вместо красной точки.
  final bool lens;

  /// Прошлые выстрелы (бледно, чтобы отличать от последнего).
  final List<Offset> ghosts;
  ShotMarkerPainter(this.placed,
      {required this.k, required this.center, this.finger, this.holeR = 4, this.labels, this.lens = false, this.ghosts = const []});

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.max(3.0, k * 2.25); // калибр 4,5 мм: растёт вместе с мишенью, без потолка
    final fill = Paint()..color = Colors.orange.withValues(alpha: 0.85);
    final edge = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final pale = Paint()..color = Colors.orange.withValues(alpha: 0.28);
    final paleEdge = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final g in ghosts) {
      final o = Offset(center.dx + g.dx * k, center.dy - g.dy * k);
      canvas.drawCircle(o, r, pale);
      canvas.drawCircle(o, r, paleEdge);
    }
    for (var i = 0; i < placed.length; i++) {
      final p = placed[i];
      final o = Offset(center.dx + p.dx * k, center.dy - p.dy * k);
      canvas.drawCircle(o, r, fill);
      canvas.drawCircle(o, r, edge);
      final lb = labels;
      if (lb != null && i < lb.length) {
        final tp = TextPainter(
          text: TextSpan(
              text: lb[i],
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 3), Shadow(blurRadius: 3)])),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(o.dx + r + 2, o.dy - tp.height / 2));
      }
    }
    final f = finger;
    if (f != null && lens) {
      // Кольцо точно по размеру пробоины (в масштабе лупы) и маленький кружок в центре
      // (диаметр 10% от диаметра пробоины) — для точного прицеливания.
      final rr = math.max(3.0, holeR);
      final dotR = math.max(1.2, rr * 0.1);
      final white = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      final dark = Paint()
        ..color = Colors.black.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2;
      for (final p in [dark, white]) {
        canvas.drawCircle(f, rr, p);
      }
      canvas.drawCircle(f, dotR + 0.9, Paint()..color = Colors.black.withValues(alpha: 0.7));
      canvas.drawCircle(f, dotR, Paint()..color = Colors.white);
    } else if (f != null) {
      final rr = holeR < 3 ? 3.0 : holeR;
      canvas.drawCircle(f, rr, Paint()..color = Colors.red.withValues(alpha: 0.8));
      canvas.drawCircle(f, rr, edge);
      final cross = Paint()
        ..color = Colors.red
        ..strokeWidth = 1;
      canvas.drawLine(f - Offset(rr + 6, 0), f + Offset(rr + 6, 0), cross);
      canvas.drawLine(f - Offset(0, rr + 6), f + Offset(0, rr + 6), cross);
    }
  }

  @override
  bool shouldRepaint(ShotMarkerPainter old) => true;
}

/// Итог финала: места, суммы, выстрелы человека.
class FinalResultScreen extends StatelessWidget {
  final Map<String, dynamic> record;

  /// Только просмотр протокола (чемпион из таблицы): без публикации и без
  /// статистики по выстрелам.
  final bool readOnly;
  final String? title;

  /// Озвучивать ли итог при открытии. Из списка финалов — нет (отзыв
  /// 82e01b13), после самого финала — да.
  final bool announce;
  const FinalResultScreen({
    super.key,
    required this.record,
    this.readOnly = false,
    this.title,
    this.announce = true,
  });

  /// Протокол финала: по каждому участнику суммы серий, одиночные выстрелы
  /// и итог (как в ведомости финалистов).
  Widget _protocol(BuildContext context, List<Map<String, dynamic>> st) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = FinalFormat.all.firstWhere((f) => f.id == record['format'], orElse: () => FinalFormat.airRifle10m);
    final shots = (record['shots'] as List).cast<Map<String, dynamic>>();
    List<double> of(String id) => [
          for (final x in shots)
            if (x['who'] == id && x['so'] != true) (x['s'] as num).toDouble()
        ];
    String f1(double v) => v.toStringAsFixed(1);
    final seriesCols = fmt.seriesShots.length;
    final cols = <String>[
      '#',
      tr('Участник'),
      for (var i = 0; i < seriesCols; i++) (i == 0 && fmt.hasOpenStage) ? tr('Откр.') : 'C${i + 1 - (fmt.hasOpenStage ? 1 : 0)}',
      for (var i = 0; i < fmt.singleShots; i++) '${fmt.seriesShots.fold<int>(0, (a, b) => a + b) + i + 1}',
      'Σ',
    ];
    final rows = <DataRow>[];
    for (final p in st) {
      final v = of('${p['id']}');
      var at = 0;
      final cells = <DataCell>[
        DataCell(Text('${p['place'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800))),
        DataCell(Text('${p['name']}')),
      ];
      for (final n in fmt.seriesShots) {
        final part = v.skip(at).take(n).toList();
        cells.add(DataCell(Text(part.length == n ? f1(part.fold(0.0, (a, b) => a + b)) : '—')));
        at += n;
      }
      for (var i = 0; i < fmt.singleShots; i++) {
        cells.add(DataCell(Text(at + i < v.length ? f1(v[at + i]) : '')));
      }
      cells.add(DataCell(Text(f1((p['total'] as num).toDouble()), style: const TextStyle(fontWeight: FontWeight.w800))));
      rows.add(DataRow(color: p['user'] == true ? WidgetStatePropertyAll(cs.primary.withValues(alpha: 0.16)) : null, cells: cells));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Отзыв 41805e2d: таблицу итогов можно приблизить — на телефоне
      // мелкие десятые иначе не разобрать. Двойное касание/щипок, до 4×.
      child: InteractiveViewer(
        maxScale: 4,
        minScale: 1,
        boundaryMargin: const EdgeInsets.all(24),
        child: DataTable(
          columnSpacing: 14,
          headingRowHeight: 36,
          dataRowMinHeight: 34,
          dataRowMaxHeight: 34,
          columns: [for (final c in cols) DataColumn(label: Text(c, style: theme.textTheme.labelMedium))],
          rows: rows,
        ),
      ),
    );
  }

  /// Итог финала для озвучки: места и результаты, как у диктора.
  static String _resultSpeech(List<Map<String, dynamic>> st) {
    const places = ['Первое', 'Второе', 'Третье', 'Четвёртое', 'Пятое', 'Шестое', 'Седьмое', 'Восьмое'];
    final rows = [for (final p in st) if (p['place'] is int) p]..sort((a, b) => (a['place'] as int).compareTo(b['place'] as int));
    final parts = <String>['Финал окончен.'];
    for (final p in rows.take(8)) {
      final i = (p['place'] as int) - 1;
      if (i < 0 || i >= places.length) continue;
      final me = p['user'] == true ? ' Это вы.' : '';
      parts.add('${places[i]} место — ${VoiceTexts.spokenName('${p['name']}')}, ${(p['total'] as num).toStringAsFixed(1).replaceAll('.', ',')}.$me');
    }
    return parts.join(' ');
  }

  Future<void> _publish(BuildContext context) async {
    final store = context.read<AppDataStore>();
    final msg = ScaffoldMessenger.of(context);
    void say(String t) => msg.showSnackBar(SnackBar(content: Text(t)));
    final auth = ChatAuthService(store.db);
    if (!auth.isSignedIn) return say(tr('Войдите в мессенджер — публикация идёт через него'));
    final face = record['face'] as String;
    final shots = (record['shots'] as List).cast<Map<String, dynamic>>();
    final myId = (record['standings'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['user'] == true)['id'];
    final mine = [for (final s in shots) if (s['who'] == myId && s['so'] != true) s];
    final training = [
      for (final se in store.sessions)
        if (se.targetFaceCode == face) for (final sh in se.countingShots) sh.score
    ];
    if (checkPlausibility(training, [for (final s in mine) (s['s'] as num).toDouble()]) == Plausibility.suspicious) {
      return say(tr('Результат намного выше ваших тренировок — публикация невозможна без подтверждения тренера на месте'));
    }
    final st = ShotStats.fromPoints([for (final s in mine) ((s['x'] as num).toDouble(), (s['y'] as num).toDouble())]);
    final stats = {'mx': st.mx, 'my': st.my, 'sx': st.sx, 'sy': st.sy, 'n': st.n, 'face': face};
    final profile = '${UserProfile.firstNameOf(store.db)} ${UserProfile.lastNameOf(store.db)}'.trim();
    final name = profile.isNotEmpty ? profile : auth.nickname;

    // Достаточно своих тренировок на этой мишени и результат им не противоречит —
    // подтверждение тренера не нужно.
    final selfOk = training.length >= ChampionsService.minTrainingShotsForSelf &&
        checkPlausibility(training, [for (final s in mine) (s['s'] as num).toDouble()]) == Plausibility.ok;
    String? coachId;
    if (!selfOk) {
      final coaches = await SupabaseAuthService(store.db).fetchLinkedCoaches();
      if (!context.mounted) return;
      if (coaches.isEmpty) {
        return say(tr('Для публикации нужен связанный тренер (или не менее {n} выстрелов в ваших тренировках на этой мишени)',
            {'n': ChampionsService.minTrainingShotsForSelf}));
      }
      coachId = coaches.first.chatUserId;
    }
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Публикация')),
        content: Text(selfOk
            ? tr('Ваше имя, результат и статистика стрельбы станут видны другим сразу: по вашим тренировкам подтверждение тренера не требуется. Продолжить?')
            : tr('Ваше имя, результат и статистика стрельбы станут видны другим после подписи тренера. Продолжить?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Опубликовать'))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await ChampionsService(auth).publish(record,
        name: name,
        coachId: coachId,
        selfVerified: selfOk,
        stats: stats,
        protocolShots: [for (final s in mine) (s['s'] as num).toDouble()]);
    say(err ?? (selfOk ? tr('Опубликовано') : tr('Отправлено тренеру на подпись')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = (record['standings'] as List).cast<Map<String, dynamic>>();
    final mine = [
      for (final s in (record['shots'] as List).cast<Map<String, dynamic>>())
        if (s['who'] == st.firstWhere((e) => e['user'] == true)['id'] && s['so'] != true) (s['s'] as num).toDouble()
    ];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(title ?? tr('Итоги финала'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: AppBackdrop(kind: 'finals', child: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          if (!readOnly && announce) _ResultVoice(text: _resultSpeech(st)),
          _protocol(context, st),
          const SizedBox(height: 12),
          if (!readOnly && mine.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr('Средний выстрел {a} · лучший {b} · худший {c}', {
                'a': (mine.fold(0.0, (a, b) => a + b) / mine.length).toStringAsFixed(2),
                'b': mine.reduce((a, b) => a > b ? a : b).toStringAsFixed(1),
                'c': mine.reduce((a, b) => a < b ? a : b).toStringAsFixed(1),
              }),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 20),
          if (readOnly)
            const SizedBox.shrink()
          else if (record['custom'] == true)
            Text(tr('Свой финал: в общий рейтинг не попадает'), textAlign: TextAlign.center)
          else
            FilledButton.icon(
            onPressed: () => _publish(context),
            icon: const Icon(Icons.public),
            label: Text(tr('Опубликовать среди чемпионов')),
          ),
        ],
      )),
    );
  }
}

/// Озвучивает итог финала при открытии экрана результатов (если озвучка финалов включена).
class _ResultVoice extends StatefulWidget {
  final String text;
  const _ResultVoice({required this.text});

  @override
  State<_ResultVoice> createState() => _ResultVoiceState();
}

class _ResultVoiceState extends State<_ResultVoice> {
  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    if (FinalsPrefs.voice(db)) {
      // Ждём, пока отыграет «Финал окончен» из последней команды: фраза встаёт в очередь.
      FinalsAnnouncer.speak(widget.text, queue: true);
    }
  }

  @override
  void dispose() {
    FinalsAnnouncer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

