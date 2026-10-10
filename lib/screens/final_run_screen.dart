import 'dart:async';

import 'package:flutter/material.dart';

import '../finals/final_run.dart';
import '../finals/finals_repository.dart';
import '../i18n/i18n.dart';
import '../logic/scoring.dart';
import '../models/target_color_scheme.dart';
import '../painters/target_painter.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';

/// Ход финала: мишень, таймер, таблица восьми участников.
class FinalRunScreen extends StatefulWidget {
  final FinalRunController controller;
  final int speed;
  final AppDataStore store;
  const FinalRunScreen({super.key, required this.controller, required this.speed, required this.store});

  @override
  State<FinalRunScreen> createState() => _FinalRunScreenState();
}

class _FinalRunScreenState extends State<FinalRunScreen> {
  Timer? _timer;
  Offset? _draft; // мм от центра, y вверх
  double? _lastScore;
  bool _saved = false;

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    // Один тик = секунда симуляции; при ускорении таймер чаще.
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ widget.speed), (_) => c.tick());
  }

  void _onChange() {
    if (!mounted) return;
    if (c.phase == RunPhase.finished && !_saved) {
      _saved = true;
      _timer?.cancel();
      final rec = c.toRecord();
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

  /// Пиксели → мм от центра (y вверх).
  Offset _toMm(Offset p, Size size) {
    final mmPerPx = c.face.faceRadiusMm / (size.shortestSide / 2);
    return Offset((p.dx - size.width / 2) * mmPerPx, -(p.dy - size.height / 2) * mmPerPx);
  }

  void _fire() {
    final d = _draft;
    if (d == null) return;
    final sc = c.submitUserShot(d.dx, d.dy);
    if (sc != null) {
      setState(() {
          _lastScore = sc;
          _draft = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sighting = c.phase == RunPhase.sighting;
    final canPlace = sighting || c.userCanShoot;
    final rows = c.engine.standings;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
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
        if (leave == true) {
          _saved = true;
          _timer?.cancel();
          if (mounted) Navigator.of(context).pop();
        } else {
          c.resume();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
          leading: const SizedBox.shrink(),
          title: Row(children: [
            Expanded(child: Text(_banner(), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            Text(_time(), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          actions: [
            IconButton(
              tooltip: c.paused ? tr('Продолжить') : tr('Пауза'),
              icon: Icon(c.paused ? Icons.play_arrow : Icons.pause),
              onPressed: c.paused ? c.resume : c.pause,
            ),
          ],
        ),
        body: Column(children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + GlassHeader.height),
          // Мишень.
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(builder: (ctx, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                final mmToPx = size.shortestSide / 2 / c.face.faceRadiusMm;
                void place(Offset p) {
                  if (canPlace && !c.paused) setState(() => _draft = _toMm(p, size));
                }

                return GestureDetector(
                  onTapDown: (d) => place(d.localPosition),
                  onPanUpdate: (d) => place(d.localPosition),
                  child: Stack(children: [
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
                          [for (final s in c.shots) if (s.who == c.userId && !s.shootOff) Offset(s.x, s.y)],
                          _draft,
                          mmToPx,
                          cs.primary,
                        ),
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
              }),
            ),
          ),
          // Кнопка выстрела.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(children: [
              Expanded(
                child: Text(
                  sighting
                      ? tr('Пристрелка: выстрелы не идут в зачёт')
                      : c.userCanShoot
                          ? tr('Осталось выстрелов: {n}', {'n': c.userShotsLeft}) +
                              (_lastScore == null ? '' : ' · ${formatScore(_lastScore!, c.face)}')
                          : (c.user.active ? tr('Ждите команды') : tr('Вы выбыли')),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (sighting) TextButton(onPressed: c.skipSighting, child: Text(tr('Готов'))),
              FilledButton(
                onPressed: (_draft != null && c.userCanShoot) ? _fire : null,
                child: Text(tr('Выстрел')),
              ),
            ]),
          ),
          // Таблица.
          Expanded(
            flex: 3,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              children: [
                for (final r in rows)
                  Opacity(
                    opacity: r.active ? 1 : 0.5,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: r.isUser ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        SizedBox(width: 26, child: Text('${r.place ?? (rows.indexOf(r) + 1)}', style: const TextStyle(fontWeight: FontWeight.w800))),
                        Expanded(child: Text(r.name, overflow: TextOverflow.ellipsis)),
                        Text(r.shots.isEmpty ? '' : r.shots.last.toStringAsFixed(1), style: theme.textTheme.bodySmall),
                        const SizedBox(width: 12),
                        Text(r.total.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _MarkerPainter extends CustomPainter {
  final List<Offset> placed;
  final Offset? draft;
  final double mmToPx;
  final Color color;
  _MarkerPainter(this.placed, this.draft, this.mmToPx, this.color);

  Offset _px(Offset mm, Size s) => Offset(s.width / 2 + mm.dx * mmToPx, s.height / 2 - mm.dy * mmToPx);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (mmToPx * 2.25).clamp(3.0, 14.0); // калибр 4,5 мм
    final fill = Paint()..color = Colors.orange.withValues(alpha: 0.85);
    final edge = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final p in placed) {
      canvas.drawCircle(_px(p, size), r, fill);
      canvas.drawCircle(_px(p, size), r, edge);
    }
    final d = draft;
    if (d != null) {
      final o = _px(d, size);
      final line = Paint()
        ..color = color
        ..strokeWidth = 2;
      canvas.drawLine(o - const Offset(14, 0), o + const Offset(14, 0), line);
      canvas.drawLine(o - const Offset(0, 14), o + const Offset(0, 14), line);
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => true;
}

/// Итог финала: места, суммы, выстрелы человека.
class FinalResultScreen extends StatelessWidget {
  final Map<String, dynamic> record;
  const FinalResultScreen({super.key, required this.record});

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
          const Opacity(
            opacity: 0.5,
            child: FilledButton(onPressed: null, child: Text('Опубликовать (скоро)')),
          ),
        ],
      ),
    );
  }
}
