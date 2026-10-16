
import 'package:flutter/material.dart';

/// «Стопка» из нескольких фото одним сообщением: сверху последнее, за ним
/// ещё два слегка повёрнуты, в углу — сколько всего фото. Тап открывает сетку.
class PhotoStack extends StatelessWidget {
  final List<ImageProvider> images; // от старого к новому
  final VoidCallback onTap;
  final bool sending;
  final double size;
  const PhotoStack({super.key, required this.images, required this.onTap, this.sending = false, this.size = 220});

  @override
  Widget build(BuildContext context) {
    final n = images.length;
    final front = images.last;
    final behind = [
      if (n >= 2) images[n - 2],
      if (n >= 3) images[n - 3],
    ];
    Widget card(ImageProvider img) => ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(14)),
            child: Image(image: img, fit: BoxFit.cover, width: size, height: size, gaplessPlayback: true),
          ),
        );
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size + 24,
        height: size + 14,
        child: Stack(alignment: Alignment.center, children: [
          for (var i = behind.length - 1; i >= 0; i--)
            Transform.translate(
              offset: Offset((i == 0 ? 9 : -9).toDouble(), i == 0 ? 3 : -2),
              child: Transform.rotate(angle: (i == 0 ? 0.07 : -0.08), child: card(behind[i])),
            ),
          card(front),
          Positioned(
            right: 14,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(14)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (sending)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white)),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: Icon(Icons.photo_library_outlined, size: 14, color: Colors.white),
                  ),
                Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

