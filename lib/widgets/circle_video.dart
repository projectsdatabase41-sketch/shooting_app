import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'video_controller.dart';
import 'voice_bubble.dart' show MediaSource, formatClock;

/// «Кружок» в пузыре: видео в круге. Нажатие — воспроизвести/пауза; файл с
/// сервера при первом нажатии скачивается незаметно ([load]).
class CircleVideo extends StatefulWidget {
  final int durationSec;
  final Future<MediaSource?> Function() load;
  final double size;
  const CircleVideo({super.key, required this.durationSec, required this.load, this.size = 200});

  @override
  State<CircleVideo> createState() => _CircleVideoState();
}

class _CircleVideoState extends State<CircleVideo> {
  static _CircleVideoState? _active;

  VideoPlayerController? _c;
  bool _loading = false;

  @override
  void dispose() {
    _c?.removeListener(_onTick);
    _c?.dispose();
    if (_active == this) _active = null;
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_loading) return;
    var c = _c;
    if (c == null) {
      setState(() => _loading = true);
      try {
        final src = await widget.load();
        if (src == null) return;
        c = await videoControllerFor(src);
        await c.initialize();
        c.addListener(_onTick);
        _c = c;
      } catch (_) {
        c = null;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      if (c == null) return;
    }
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (_active != null && _active != this) await _active!._c?.pause();
      _active = this;
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final s = widget.size;
    final ready = c != null && c.value.isInitialized;
    final playing = ready && c.value.isPlaying;
    final total = ready ? c.value.duration.inMilliseconds : widget.durationSec * 1000;
    final pos = ready ? c.value.position.inMilliseconds : 0;
    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ClipOval(
              child: Container(
                width: s - 8,
                height: s - 8,
                color: Colors.black87,
                child: ready
                    ? FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: c.value.size.width,
                          height: c.value.size.height,
                          child: VideoPlayer(c),
                        ),
                      )
                    : null,
              ),
            ),
            SizedBox(
              width: s,
              height: s,
              child: CircularProgressIndicator(
                value: total <= 0 ? 0 : (pos / total).clamp(0.0, 1.0),
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
            if (_loading)
              const CircularProgressIndicator(color: Colors.white)
            else if (!playing)
              const Icon(Icons.play_circle_fill, size: 52, color: Colors.white70),
            Positioned(
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  formatClock(playing || pos > 0 ? (total - pos) ~/ 1000 : widget.durationSec),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
