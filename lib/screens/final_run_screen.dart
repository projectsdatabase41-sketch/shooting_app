import '../widgets/glass_route.dart';
import '../widgets/app_backdrop.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../finals/announcer.dart';
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

/// Ход финала: сверху мишень спортсмена (~40% экрана), ниже мишени соперников,
/// свайпом вправо — таблица результатов.
class FinalRunScreen extends StatefulWidget {
  final FinalRunController controller;
  final AppDataStore store;
  final bool custom; // «свой финал» — не публикуется
  const FinalRunScreen({super.key, required this.controller, required this.store, this.custom = false});

  @override
  State<FinalRunScreen> createState() => _FinalRunScreenState();
}

class _FinalRunScreenState extends State<FinalRunScreen> {
  Timer? _timer;
  final List<Offset> _sightingMarks = []; // мм, пристрелка не идёт в зачёт
  final _page = PageController(initialPage: 1);
  bool _saved = false;
  bool _holding = false;

  /// Финал не стартует сам: часы пойдут после кнопки «Начать финал».
  bool _started = false;
  final String _layout = 'classic'; // вид экрана один (раскладки убраны из настройки)
  late final bool _voice = FinalsPrefs.voice(widget.store.db);
  final _tracker = AnnounceTracker();
  final _phaseVoice = PhaseAnnouncer();

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
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
    if (_voice) {
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
    FinalsAnnouncer.stop();
    _timer?.cancel();
    _page.dispose();
    c.removeListener(_onChange);
    super.dispose();
  }

  void _begin() {
    if (_started) return;
    setState(() => _started = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => c.tick());
  }

  String _banner() {
    switch (c.phase) {
      case RunPhase.sighting:
        return tr('Подготовка и пристрелка');
      case RunPhase.loading:
        return c.announcing ? tr('Комментарий диктора') : tr('Заряжай… старт через {n} с', {'n': c.secondsLeft});
      case RunPhase.finished:
        return tr('Финал окончен');
      case RunPhase.grace:
        return tr('Стоп! Отметьте выстрел');
      case RunPhase.shooting:
        final l = c.roundLabel;
        if (l == 'shootoff') return tr('Перестрелка');
        if (l == 'open') return tr('С колена и лёжа: 20 выстрелов');
        final n = l.split(':')[1];
        return l.startsWith('series') ? tr('Серия {n}', {'n': n}) : tr('Выстрел {n}', {'n': n});
    }
  }

  String _time() {
    final s = switch (c.phase) {
      RunPhase.shooting => (c.roundLimit - c.roundSeconds).clamp(0, 9999),
      _ => c.secondsLeft,
    };
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
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
        appBar: GlassHeader(
          // «Назад»: с таблицы — на главный экран финала, оттуда — выход из финала.
          leading: IconButton(
            tooltip: tr('Назад'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_page.hasClients && (_page.page ?? 1) < 0.5) {
                _page.animateToPage(1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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
            IconButton(
              tooltip: c.paused ? tr('Продолжить') : tr('Пауза'),
              icon: Icon(c.paused ? Icons.play_arrow : Icons.pause),
              onPressed: c.paused ? c.resume : c.pause,
            ),
            IconButton(
              tooltip: tr('Покинуть финал'),
              icon: const Icon(Icons.logout),
              onPressed: _leave,
            ),
          ],
        ),
        // Таблица слева (свайп вправо), главный экран справа.
        body: Stack(children: [
          Positioned.fill(
            child: PageView(
              controller: _page,
              physics: _holding ? const NeverScrollableScrollPhysics() : null,
              children: [_layout == 'table' ? _botsPage(context) : _table(context), _main(context)],
            ),
          ),
          if (!_started)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.72),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.emoji_events_outlined, color: Colors.white, size: 52),
                    const SizedBox(height: 12),
                    Text(tr('Всё готово'), style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(tr('Подготовка и пристрелка начнутся после нажатия'), style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _begin,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(tr('Начать финал')),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _main(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top + GlassHeader.height;
    final h = MediaQuery.sizeOf(context).height;
    final bots = [for (final x in c.engine.competitors) if (!x.isUser) x];
    final sighting = c.phase == RunPhase.sighting;
    final marks = _myMarks;
    final pad = Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Stack(children: [
        Positioned.fill(
          child: ShotPad(
            face: c.face,
            marks: marks,
            enabled: _canPlace && !c.paused,
            onHold: (v) => setState(() => _holding = v),
            onShot: _onShot,
          ),
        ),
        if (c.paused)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(child: Text(tr('Пауза'), style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white))),
            ),
          ),
      ]),
    );
    final side = _layout == 'side';
    // По умолчанию: три бота над моей мишенью, остальные ниже (лупа не перескакивает).
    final stacked = !side && _layout != 'table';
    final rest = (side || stacked) ? bots.skip(3).toList() : bots;
    return Column(children: [
      SizedBox(height: top),
      if (stacked)
        SizedBox(
          height: h * 0.14,
          child: Row(children: [for (final b in bots.take(3)) Expanded(child: _BotCard(c: c, bot: b))]),
        ),
      Text(c.user.name, style: theme.textTheme.titleSmall),
      SizedBox(
        height: stacked ? h * 0.36 : h * 0.46,
        child: side
            ? Row(children: [
                Expanded(flex: 5, child: pad),
                Expanded(
                  flex: 3,
                  child: Column(children: [
                    for (final b in bots.take(3)) Expanded(child: _BotCard(c: c, bot: b)),
                  ]),
                ),
              ])
            : pad,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text(
              sighting
                  ? tr('Пристрелка: выстрелы не идут в зачёт')
                  : c.userCanShoot
                      ? tr('Осталось выстрелов: {n}', {'n': c.userShotsLeft}) +
                          (marks.isEmpty
                              ? ''
                              : ' · ${[for (final m in marks) formatScore(scoreForPoint(m.dx, m.dy, c.face), c.face)].join(' ')}')
                      : (c.user.active ? tr('Ждите команды') : tr('Вы выбыли — боты продолжают')),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (sighting) TextButton(onPressed: c.skipSighting, child: Text(tr('Готов'))),
          if (!c.user.active && c.phase != RunPhase.finished)
            TextButton(onPressed: c.fastForward, child: Text(tr('Завершить результат'))),
          TextButton.icon(
            onPressed: marks.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
            label: Text(tr('Назад')),
          ),
        ]),
      ),
      Expanded(
        child: _layout == 'table'
            ? _table(context, embedded: true)
            : GridView.count(
                crossAxisCount: stacked ? 4 : 3,
                childAspectRatio: stacked ? 0.8 : 0.85,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [for (final b in rest) _BotCard(c: c, bot: b)],
              ),
      ),
    ]);
  }

  /// Страница с мишенями соперников (вид «мишень и таблица на одной странице»).
  Widget _botsPage(BuildContext context) {
    final bots = [for (final x in c.engine.competitors) if (!x.isUser) x];
    return GridView.count(
      crossAxisCount: 3,
      childAspectRatio: 0.85,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 8, 16),
      children: [for (final b in bots) _BotCard(c: c, bot: b)],
    );
  }

  Widget _table(BuildContext context, {bool embedded = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rows = c.live;
    return ListView(
      padding: embedded
          ? const EdgeInsets.fromLTRB(12, 0, 12, 12)
          : EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 16),
      children: [
        for (var i = 0; i < rows.length; i++)
          Opacity(
            opacity: rows[i].c.active ? 1 : 0.5,
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: rows[i].c.isUser ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                SizedBox(
                    width: 26,
                    child: Text('${rows[i].c.place ?? (i + 1)}', style: const TextStyle(fontWeight: FontWeight.w800))),
                Expanded(child: Text(rows[i].c.name, overflow: TextOverflow.ellipsis)),
                Text(rows[i].shots.isEmpty ? '' : '${rows[i].shots.last.toStringAsFixed(1)}  ', style: theme.textTheme.bodySmall),
                Text(rows[i].total.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ],
    );
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
  const ShotPad({required this.face, required this.marks, required this.enabled, required this.onHold, required this.onShot});

  @override
  State<ShotPad> createState() => _ShotPadState();
}

class _ShotPadState extends State<ShotPad> {
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

  double _k(Size s) => s.shortestSide / 2 / widget.face.faceRadiusMm;

  Offset _toMm(Offset p, Size s) {
    final k = _k(s);
    return Offset((p.dx - s.width / 2) / k, -(p.dy - s.height / 2) / k);
  }

  void _down(Offset f, Size s) {
    if (!widget.enabled) return;
    setState(() => _finger = f);
    widget.onHold(true);
  }

  void _up(Size s) {
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
                          colors: TargetColorScheme.defaultScheme,
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
      return Listener(
        onPointerDown: (e) => _down(e.localPosition, size),
        onPointerMove: (e) {
          if (_finger != null) setState(() => _finger = e.localPosition);
        },
        onPointerUp: (_) => _up(size),
        onPointerCancel: (_) {
          setState(() => _finger = null);
          widget.onHold(false);
        },
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: CustomPaint(
              painter: TargetPainter(
                face: widget.face,
                colors: TargetColorScheme.defaultScheme,
                visibleShots: const [],
                selectedShot: null,
                currentSeriesNo: 1,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: ShotMarkerPainter(widget.marks, k: k, center: Offset(size.width / 2, size.height / 2), finger: f, holeR: 4, labels: [for (final m in widget.marks) formatScore(scoreForPoint(m.dx, m.dy, widget.face), widget.face)]),
            ),
          ),
        ]),
      );
    });
  }
}

/// Мишень соперника: имя, последняя пробоина, значение и направление стрелкой.
class _BotCard extends StatelessWidget {
  final FinalRunController c;
  final FinalCompetitor bot;
  const _BotCard({required this.c, required this.bot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = [for (final s in c.shots) if (s.who == bot.id && !s.shootOff) s];
    final last = mine.isEmpty ? null : mine.last;
    return Opacity(
      opacity: bot.active ? 1 : 0.45,
      child: Column(children: [
        Text(bot.name, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        Expanded(
          child: LayoutBuilder(builder: (ctx, box) {
            // Мишень соперника приближается к центру, пока пробоина умещается;
            // сильный промах уменьшает зум, чтобы пробоина осталась видна.
            final dist = last == null ? 0.0 : math.sqrt(last.x * last.x + last.y * last.y);
            final zoom = last == null ? 1.0 : (c.face.faceRadiusMm * 0.8 / math.max(dist, 1.0)).clamp(1.0, 4.0);
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
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: ShotMarkerPainter(
                    last == null ? const [] : [Offset(last.x, last.y)],
                    ghosts: [
                      for (final g in c.sightShots[bot.id] ?? const <(double, double)>[]) Offset(g.$1, g.$2),
                      for (final g in mine.take(math.max(0, mine.length - 1))) Offset(g.x, g.y),
                    ],
                    k: k,
                    center: Offset(box.maxWidth / 2, box.maxHeight / 2),
                  ),
                ),
              ),
            ]));
          }),
        ),
        SizedBox(
          height: 18,
          child: last == null
              ? null
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(last.score.toStringAsFixed(1), style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (last.x != 0 || last.y != 0)
                    Transform.rotate(
                      angle: math.atan2(last.x, last.y), // 0 = вверх, по часовой
                      child: const Icon(Icons.arrow_upward, size: 14),
                    ),
                ]),
        ),
      ]),
    );
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
    final r = (k * 2.25).clamp(3.0, 14.0); // калибр 4,5 мм
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
      final rr = holeR.clamp(4.0, 16.0);
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
        canvas.drawLine(f - Offset(rr + 14, 0), f - Offset(rr + 2, 0), p);
        canvas.drawLine(f + Offset(rr + 2, 0), f + Offset(rr + 14, 0), p);
        canvas.drawLine(f - Offset(0, rr + 14), f - Offset(0, rr + 2), p);
        canvas.drawLine(f + Offset(0, rr + 2), f + Offset(0, rr + 14), p);
      }
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
  const FinalResultScreen({super.key, required this.record, this.readOnly = false, this.title});

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
      child: DataTable(
        columnSpacing: 14,
        headingRowHeight: 36,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 34,
        columns: [for (final c in cols) DataColumn(label: Text(c, style: theme.textTheme.labelMedium))],
        rows: rows,
      ),
    );
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
