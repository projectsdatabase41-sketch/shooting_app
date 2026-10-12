import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  final int speed;
  final AppDataStore store;
  final bool custom; // «свой финал» — не публикуется
  const FinalRunScreen({super.key, required this.controller, required this.speed, required this.store, this.custom = false});

  @override
  State<FinalRunScreen> createState() => _FinalRunScreenState();
}

class _FinalRunScreenState extends State<FinalRunScreen> {
  Timer? _timer;
  final List<Offset> _sightingMarks = []; // мм, пристрелка не идёт в зачёт
  final _page = PageController(initialPage: 1);
  bool _saved = false;
  bool _holding = false;

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ widget.speed), (_) => c.tick());
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
    setState(() {});
  }

  @override
  void dispose() {
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
        return tr('Заряжай… старт через {n} с', {'n': c.secondsLeft});
      case RunPhase.finished:
        return tr('Финал окончен');
      case RunPhase.grace:
        return tr('Стоп! Отметьте выстрел');
      case RunPhase.shooting:
        final l = c.roundLabel;
        if (l == 'shootoff') return tr('Перестрелка');
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
        content: Text(tr('Результат не будет сохранён.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Остаться'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Выйти'))),
        ],
      ),
    );
    if (leave != true) c.resume();
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave()) {
          _saved = true;
          _timer?.cancel();
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
          leading: const SizedBox.shrink(),
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
    return Column(children: [
      SizedBox(height: top),
      Text(c.user.name, style: theme.textTheme.titleSmall),
      SizedBox(
        height: h * 0.40,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          child: Stack(children: [
            Positioned.fill(
              child: _UserPad(
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
        ),
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
                      : (c.user.active ? tr('Ждите команды') : tr('Вы выбыли')),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (sighting) TextButton(onPressed: c.skipSighting, child: Text(tr('Готов'))),
          TextButton.icon(
            onPressed: marks.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
            label: Text(tr('Назад')),
          ),
        ]),
      ),
      Expanded(
        child: GridView.count(
          crossAxisCount: 4,
          childAspectRatio: 0.72,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          children: [for (final b in bots) _BotCard(c: c, bot: b)],
        ),
      ),
    ]);
  }

  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rows = c.engine.standings;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 16),
      children: [
        for (final r in rows)
          Opacity(
            opacity: r.active ? 1 : 0.5,
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: r.isUser ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                SizedBox(
                    width: 26,
                    child: Text('${r.place ?? (rows.indexOf(r) + 1)}', style: const TextStyle(fontWeight: FontWeight.w800))),
                Expanded(child: Text(r.name, overflow: TextOverflow.ellipsis)),
                Text(r.shots.isEmpty ? '' : '${r.shots.last.toStringAsFixed(1)}  ', style: theme.textTheme.bodySmall),
                Text(r.shots.isEmpty ? '' : '${tr('ср')} ${(r.total / r.shots.length).toStringAsFixed(2)}  ',
                    style: theme.textTheme.bodySmall),
                Text(r.total.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Мишень спортсмена: удержание увеличивает место нажатия, пробоина — размером
/// с палец, вокруг кольцо и значение над ним; отпускание сохраняет выстрел.
class _UserPad extends StatefulWidget {
  final TargetFace face;
  final List<Offset> marks;
  final bool enabled;
  final ValueChanged<bool> onHold;
  final ValueChanged<Offset> onShot;
  const _UserPad({required this.face, required this.marks, required this.enabled, required this.onHold, required this.onShot});

  @override
  State<_UserPad> createState() => _UserPadState();
}

class _UserPadState extends State<_UserPad> {
  static const double _zoom = 5;
  Offset? _finger; // px
  Offset _pan = Offset.zero;
  double _z = 1;

  double _k(Size s) => s.shortestSide / 2 * _z / widget.face.faceRadiusMm;

  Offset _toMm(Offset p, Size s) {
    final k = _k(s);
    final c = Offset(s.width / 2, s.height / 2) + _pan;
    return Offset((p.dx - c.dx) / k, -(p.dy - c.dy) / k);
  }

  void _reset() {
    _finger = null;
    _z = 1;
    _pan = Offset.zero;
  }

  void _down(Offset f, Size s) {
    if (!widget.enabled) return;
    final p = _toMm(f, s); // пока zoom = 1, pan = 0
    _z = _zoom;
    final k = _k(s);
    _pan = f - Offset(s.width / 2, s.height / 2) - Offset(p.dx * k, -p.dy * k);
    setState(() => _finger = f);
    widget.onHold(true);
  }

  void _up(Size s) {
    final f = _finger;
    if (f == null) return;
    final mm = _toMm(f, s);
    setState(_reset);
    widget.onHold(false);
    widget.onShot(mm);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final f = _finger;
      String? score;
      if (f != null) {
        final mm = _toMm(f, size);
        score = formatScore(scoreForPoint(mm.dx, mm.dy, widget.face), widget.face);
      }
      return Listener(
        onPointerDown: (e) => _down(e.localPosition, size),
        onPointerMove: (e) {
          if (_finger != null) setState(() => _finger = e.localPosition);
        },
        onPointerUp: (_) => _up(size),
        onPointerCancel: (_) {
          setState(_reset);
          widget.onHold(false);
        },
        child: ClipRect(
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: TargetPainter(
                  face: widget.face,
                  colors: TargetColorScheme.defaultScheme,
                  visibleShots: const [],
                  selectedShot: null,
                  currentSeriesNo: 1,
                  zoom: _z,
                  pan: _pan,
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _MarkerPainter(
                  widget.marks,
                  k: _k(size),
                  center: Offset(size.width / 2, size.height / 2) + _pan,
                  finger: f,
                  score: score,
                  ring: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ]),
        ),
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
                  painter: _MarkerPainter(
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

class _MarkerPainter extends CustomPainter {
  final List<Offset> placed; // мм
  final double k; // px на мм
  final Offset center;
  final Offset? finger;
  final String? score;
  final Color ring;
  _MarkerPainter(this.placed, {required this.k, required this.center, this.finger, this.score, this.ring = Colors.blue});

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
      // Пробоина — размером с палец, кольцо больше, значение над кольцом.
      canvas.drawCircle(f, 20, Paint()..color = Colors.orange.withValues(alpha: 0.7));
      canvas.drawCircle(f, 20, edge);
      canvas.drawCircle(
          f,
          34,
          Paint()
            ..color = ring
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      if (score != null) {
        final tp = TextPainter(
          text: TextSpan(
              text: score,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 4)])),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(f.dx - tp.width / 2, f.dy - 34 - 8 - tp.height));
      }
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => true;
}

/// Итог финала: места, суммы, выстрелы человека.
class FinalResultScreen extends StatelessWidget {
  final Map<String, dynamic> record;
  const FinalResultScreen({super.key, required this.record});

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
    final cs = theme.colorScheme;
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
          for (final s in st)
            Card(
              color: s['user'] == true ? cs.primary.withValues(alpha: 0.16) : null,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: ((s['place'] as int?) ?? 9) <= 3 ? const Color(0xFFD9A441) : cs.surfaceContainerHigh,
                  child: Text('${s['place'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                title: Text('${s['name']}'),
                trailing: Text((s['total'] as num).toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
          const SizedBox(height: 12),
          Text(tr('Ваши выстрелы'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final v in mine) Chip(label: Text(v.toStringAsFixed(1)), visualDensity: VisualDensity.compact),
          ]),
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
