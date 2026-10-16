import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Анимация ожидания (цикличное видео) вместо обычного колеса загрузки.
/// Если видео не запускается (нет плагина, тесты, сбой декодера), показывается
/// обычный индикатор — ожидание не должно ломаться из-за анимации.
class AppLoader extends StatefulWidget {
  /// Ширина окна анимации; высота — по пропорциям видео.
  final double width;
  const AppLoader({super.key, this.width = 150});

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.asset('assets/video/loading.mp4', videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      _c = c;
      await c.initialize();
      await c.setVolume(0);
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed || c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final ratio = c.value.aspectRatio;
    return LayoutBuilder(builder: (context, box) {
      // Не вылезаем за отведённое место: ширина подгоняется под доступную высоту.
      final maxH = box.maxHeight.isFinite ? box.maxHeight : 400.0;
      final w = [widget.width, maxH * ratio, box.maxWidth.isFinite ? box.maxWidth : widget.width].reduce((a, b) => a < b ? a : b);
      if (w < 48) return const Center(child: CircularProgressIndicator());
      return Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(width: w, child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(c))),
        ),
      );
    });
  }
}
