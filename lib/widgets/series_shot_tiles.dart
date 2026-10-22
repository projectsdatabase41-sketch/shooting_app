import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../painters/target_painter.dart';
import '../models/target_color_scheme.dart';

/// Строка выстрела в списке серии: номер в кружке, результат в таблетке той же высоты, справа
/// координаты и значок заметок (если они есть). Без размытия подложки — строк в серии много.
class SeriesShotRow extends StatelessWidget {
  final Shot shot;
  final int notes;
  final VoidCallback onTap;
  const SeriesShotRow({super.key, required this.shot, required this.notes, required this.onTap});

  static const double _h = 38.4; // 80% от кнопки «назад» (48)

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = cs.surface.withValues(alpha: 0.6);
    final side = BorderSide(color: cs.onSurface.withValues(alpha: 0.08));
    final small = Theme.of(context).textTheme.bodySmall;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(children: [
          Material(
            color: bg,
            shape: CircleBorder(side: side),
            child: SizedBox(width: _h, height: _h, child: Center(child: Text('${shot.shotNumber}', style: const TextStyle(fontWeight: FontWeight.w700)))),
          ),
          const SizedBox(width: 8),
          Material(
            color: bg,
            shape: StadiumBorder(side: side),
            child: SizedBox(
              height: _h,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Center(child: Text(shot.score.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              ),
            ),
          ),
          const Spacer(),
          Text('x-y  ${shot.xMm.toStringAsFixed(1)} - ${shot.yMm.toStringAsFixed(1)}', style: small),
          if (notes > 0) ...[
            const SizedBox(width: 10),
            Icon(Icons.sticky_note_2_outlined, size: 18, color: cs.primary),
            const SizedBox(width: 2),
            Text('$notes', style: small?.copyWith(color: cs.primary)),
          ],
        ]),
      ),
    );
  }
}

/// «Заметок: N» рядом со значком — для списка серий.
class SeriesNotesBadge extends StatelessWidget {
  final int count;
  const SeriesNotesBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.sticky_note_2_outlined, size: 18, color: cs.primary),
      const SizedBox(width: 4),
      Text(tr('заметок: {n}', {'n': count}), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.primary)),
      const SizedBox(width: 8),
    ]);
  }
}

/// Направление от центра: градусы (0 — вверх, по часовой) и сторона света.
(int, String) shotDirection(Shot s) {
  if (s.xMm == 0 && s.yMm == 0) return (0, '•');
  var deg = math.atan2(s.xMm, s.yMm) * 180 / math.pi;
  if (deg < 0) deg += 360;
  const arrows = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖'];
  return (deg.round() % 360, arrows[((deg + 22.5) ~/ 45) % 8]);
}

/// Мишень выстрела, приближенная к месту попадания, и данные выстрела — как при стрельбе в тренировке.
class SingleShotInfo extends StatelessWidget {
  final Shot shot;
  final TargetFace face;
  final TargetColorScheme colors;
  const SingleShotInfo({super.key, required this.shot, required this.face, required this.colors});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dist = math.sqrt(shot.xMm * shot.xMm + shot.yMm * shot.yMm);
    final (deg, arrow) = shotDirection(shot);
    // Чем ближе выстрел к центру, тем сильнее приближение: мишень в окошке не остаётся мелкой.
    final visible = math.max(dist * 1.8, face.faceRadiusMm * 0.15);
    final zoom = (face.faceRadiusMm / visible).clamp(1.0, 8.0).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(builder: (context, c) {
          final radiusPx = math.min(c.maxWidth, c.maxHeight) / 2 * zoom;
          final k = radiusPx / face.faceRadiusMm;
          // Сдвиг: попадание — в центр окошка.
          final pan = Offset(-shot.xMm * k, shot.yMm * k);
          return ClipRect(
            child: CustomPaint(
              painter: TargetPainter(
                face: face,
                colors: colors,
                visibleShots: [shot],
                selectedShot: shot,
                currentSeriesNo: shot.seriesNo,
                zoom: zoom,
                pan: pan,
              ),
            ),
          );
        }),
      ),
      const SizedBox(height: 16),
      Text(tr('Результат: {p}', {'p': shot.score.toStringAsFixed(1)}), style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('x-y  ${shot.xMm.toStringAsFixed(2)} - ${shot.yMm.toStringAsFixed(2)} ${tr('мм')}', style: theme.textTheme.bodyMedium),
      Text(tr('Отклонение от центра: {d} мм', {'d': dist.toStringAsFixed(2)}), style: theme.textTheme.bodyMedium),
      Text(tr('Направление: {a}° {s}', {'a': deg, 's': arrow}), style: theme.textTheme.bodyMedium),
    ]);
  }
}
