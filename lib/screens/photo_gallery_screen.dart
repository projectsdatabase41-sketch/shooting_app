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
      body: GridView.builder(
        padding: EdgeInsets.fromLTRB(4, MediaQuery.paddingOf(context).top + GlassHeader.height + 4, 4, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
        itemCount: images.length,
        itemBuilder: (context, i) => GestureDetector(
          onTap: () => PhotoViewerScreen.open(context, images[i]),
          child: Image(image: images[i], fit: BoxFit.cover, gaplessPlayback: true),
        ),
      ),
    );
  }
}
