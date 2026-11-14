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

class _PhotoCard extends StatelessWidget {
  final ImageProvider image;
  final int number;
  final VoidCallback onTap;
  const _PhotoCard({required this.image, required this.number, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        child: Stack(children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Image(image: image, fit: BoxFit.cover, gaplessPlayback: true),
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
              child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ]),
      ),
    );
  }
}
