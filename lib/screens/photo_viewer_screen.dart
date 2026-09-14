import 'package:flutter/material.dart';

/// Просмотр фото на весь экран (тап по фото в чате) — тёмный фон,
/// пинч-зум через InteractiveViewer, закрытие тапом по крестику или
/// системной кнопкой "назад".
class PhotoViewerScreen extends StatelessWidget {
  final ImageProvider image;
  const PhotoViewerScreen({super.key, required this.image});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          child: Image(image: image, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
