import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/glass_pill.dart';
import 'photo_viewer_screen.dart';

/// Все фото из «стопки» сеткой; тап открывает фото на весь экран.
class PhotoGalleryScreen extends StatelessWidget {
  final List<ImageProvider> images;
  const PhotoGalleryScreen({super.key, required this.images});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Фото: {n}', {'n': images.length}),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      // Стопка «картами»: раньше фото лежали плотной сеткой по три в ряд и
      // было непонятно, где какое (отзыв 13.11: «не красиво они
      // располагаются, лучше пусть будут как карты»). Теперь это лента
      // крупных карточек со скруглениями и тенью — тап открывает нужную.
      body: ListView.separated(
        padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 24),
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _PhotoCard(
          image: images[i],
          number: i + 1,
          onTap: () => PhotoViewerScreen.open(context, images[i]),
        ),
      ),
    );
  }
}

class _PhotoCard extends StatefulWidget {
  final ImageProvider image;
  final int number;
  final VoidCallback onTap;
  const _PhotoCard({required this.image, required this.number, required this.onTap});

  @override
  State<_PhotoCard> createState() => _PhotoCardState();
}

class _PhotoCardState extends State<_PhotoCard> {
  bool _hovered = false;

  // Создаёт матрицу трансформации для 3D-эффекта наведения.
  // Собираем из вращения и переноса, не используя deprecated translate().
  Matrix4 _buildTransform() {
    const tx = 0.0;
    final ty = _hovered ? -4.0 : 0.0;
    const tz = 0.0;
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.001) // perspective
      ..rotateX(_hovered ? -0.02 : 0.0)
      ..rotateY(_hovered ? 0.02 : 0.0);
    // Применяем перенос через умножение на матрицу переноса
    return Matrix4.translationValues(tx, ty, tz) * m;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Мягкие тени + лёгкая перспектива (3D-эффект), заметны и на тёмной теме.
    final baseShadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.18),
        blurRadius: 24,
        offset: const Offset(0, 10),
        spreadRadius: -4,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.08),
        blurRadius: 6,
        offset: const Offset(0, 2),
      ),
    ];
    final hoverShadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.28),
        blurRadius: 36,
        offset: const Offset(0, 16),
        spreadRadius: -6,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.12),
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
    ];

    // Лёгкий 3D-накллон при наведении (только десктоп/веб).
    final transform = _buildTransform();

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: transform,
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          boxShadow: _hovered ? hoverShadow : baseShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Stack(children: [
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image(image: widget.image, fit: BoxFit.cover, gaplessPlayback: true),
              ),
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${widget.number}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
