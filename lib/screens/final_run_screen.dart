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
  late final String _layout = FinalsPrefs.layout(widget.store.db);
  late final bool _voice = FinalsPrefs.voice(widget.store.db);
  final _tracker = AnnounceTracker();

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => c.tick());
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
      final text = _tracker.update(
        [for (final r in c.live) AnnounceRow(r.c.name, r.total, r.c.active, isMe: r.c.id == c.userId)],
        announcing: c.announcing,
      );
      if (text != null) FinalsAnnouncer.speak(text);
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
    final leave = await showDialog<bool>(
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
        body: PageView(
          controller: _page,
          physics: _holding ? const NeverScrollableScrollPhysics() : null,
          children: [_table(context), _main(context)],
        ),
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
    final rest = side ? bots.skip(3).toList() : bots;
    return Column(children: [
      SizedBox(height: top),
      Text(c.user.name, style: theme.textTheme.titleSmall),
      SizedBox(
        height: h * 0.40,
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
                      ? tr('Осталось выстрелов: {n}', {'n': c.userShotsLeft})
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
        child: GridView.count(
          crossAxisCount: side ? 3 : 4,
          childAspectRatio: side ? 0.9 : 0.72,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          children: [for (final b in rest) _BotCard(c: c, bot: b)],
        ),
      ),
    ]);
  }

  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rows = c.live;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 16),
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
                Text(rows[i].shots.isEmpty ? '' : '${tr('ср')} ${rows[i].avg.toStringAsFixed(2)}  ', style: theme.textTheme.bodySmall),
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
  static const double _zoom = 6; // увеличение в лупе
  static const double _loupe = 140; // диаметр лупы, px
  static const double _gap = 100; // от пальца до центра лупы
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final k = _k(size);
      final f = _finger;
      Widget? loupe;
      if (f != null) {
        final mm = _toMm(f, size);
        final score = formatScore(scoreForPoint(mm.dx, mm.dy, widget.face), widget.face);
        // Лупа над пальцем; у верхнего края — под пальцем.
        var cy = f.dy - _gap;
        if (cy - _loupe / 2 < 0) cy = f.dy + _gap;
        final cx = f.dx.clamp(_loupe / 2, size.width - _loupe / 2);
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
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
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
                        painter: ShotMarkerPainter(widget.marks, k: kz, center: lc, finger: Offset(_loupe / 2, _loupe / 2), holeR: 2.25 * kz),
                      ),
                    ),
                  ]),
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
              painter: ShotMarkerPainter(widget.marks, k: k, center: Offset(size.width / 2, size.height / 2), finger: f, holeR: 4),
            ),
          ),
          if (loupe != null) loupe,
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
            final k = box.biggest.shortestSide / 2 / c.face.faceRadiusMm;
            return Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: TargetPainter(
                    face: c.face,
                    colors: TargetColorScheme.defaultScheme,
                    visibleShots: const [],
                    selectedShot: null,
                    currentSeriesNo: 1,
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: ShotMarkerPainter(
                    last == null ? const [] : [Offset(last.x, last.y)],
                    k: k,
                    center: Offset(box.maxWidth / 2, box.maxHeight / 2),
                  ),
                ),
              ),
            ]);
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
  ShotMarkerPainter(this.placed, {required this.k, required this.center, this.finger, this.holeR = 4});

  @override
  void paint(Canvas canvas, Size size) {
    final r = (k * 2.25).clamp(3.0, 14.0); // калибр 4,5 мм
    final fill = Paint()..color = Colors.orange.withValues(alpha: 0.85);
    final edge = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final p in placed) {
      final o = Offset(center.dx + p.dx * k, center.dy - p.dy * k);
      canvas.drawCircle(o, r, fill);
      canvas.drawCircle(o, r, edge);
    }
    final f = finger;
    if (f != null) {
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
  const FinalResultScreen({super.key, required this.record});

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
    final coaches = await SupabaseAuthService(store.db).fetchLinkedCoaches();
    if (!context.mounted) return;
    if (coaches.isEmpty) return say(tr('Для публикации нужен связанный тренер: он подписывает результат'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Публикация')),
        content: Text(tr('Ваше имя, результат и статистика стрельбы станут видны другим после подписи тренера {c}. Продолжить?', {'c': coaches.first.nickname.isNotEmpty ? coaches.first.nickname : coaches.first.label})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Опубликовать'))),
        ],
      ),
    );
    if (ok != true) return;
    final st = ShotStats.fromPoints([for (final s in mine) ((s['x'] as num).toDouble(), (s['y'] as num).toDouble())]);
    final err = await ChampionsService(auth).publish(record,
        name: auth.nickname,
        coachId: coaches.first.chatUserId,
        stats: {'mx': st.mx, 'my': st.my, 'sx': st.sx, 'sy': st.sy, 'n': st.n, 'face': face});
    say(err ?? tr('Отправлено тренеру на подпись'));
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
      appBar: GlassHeader(title: Text(tr('Итоги финала'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          _protocol(context, st),
          const SizedBox(height: 12),
          Text(tr('Ваши выстрелы'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in mine) Chip(label: Text(v.toStringAsFixed(1)), visualDensity: VisualDensity.compact),
          ]),
          if (mine.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr('Средний выстрел {a} · лучший {b} · худший {c} · десяток от 10.0: {d}', {
                'a': (mine.fold(0.0, (a, b) => a + b) / mine.length).toStringAsFixed(2),
                'b': mine.reduce((a, b) => a > b ? a : b).toStringAsFixed(1),
                'c': mine.reduce((a, b) => a < b ? a : b).toStringAsFixed(1),
                'd': mine.where((v) => v >= 10.0).length,
              }),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 20),
          if (record['custom'] == true)
            Text(tr('Свой финал: в общий рейтинг не попадает'), textAlign: TextAlign.center)
          else
            FilledButton.icon(
            onPressed: () => _publish(context),
            icon: const Icon(Icons.public),
            label: Text(tr('Опубликовать среди чемпионов')),
          ),
        ],
      ),
    );
  }
}
