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

  /// Идёт отправка (свой кружок) или скачивание (чужой): плавная пульсация и бегущая дуга вместо кнопки «играть».
  final bool busy;

  /// Доля передачи 0…1, если известна (прямая передача); иначе дуга бежит по кругу.
  final double? progress;
  const CircleVideo({super.key, required this.durationSec, required this.load, this.size = 200, this.busy = false, this.progress});

  @override
  State<CircleVideo> createState() => _CircleVideoState();
}

class _CircleVideoState extends State<CircleVideo> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  static _CircleVideoState? _active;

  VideoPlayerController? _c;
  bool _loading = false;

  @override
  void didUpdateWidget(CircleVideo old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  bool get _working => widget.busy || _loading;

  void _syncPulse() {
    if (_working && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!_working && _pulse.isAnimating) {
      _pulse.animateTo(0, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
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
      _syncPulse();
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
        if (mounted) {
          setState(() => _loading = false);
          _syncPulse();
        }
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
    final ready = c != null && c.value.isInitialized;
    final playing = ready && c.value.isPlaying;
    // Во время просмотра кружок увеличивается вдвое (но не шире экрана).
    final target = playing ? (widget.size * 2).clamp(widget.size, MediaQuery.sizeOf(context).width * 0.88).toDouble() : widget.size;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, s, _) => _circle(c, s, ready, playing),
    );
  }

  Widget _circle(VideoPlayerController? c, double s, bool ready, bool playing) {
    final total = ready ? c!.value.duration.inMilliseconds : widget.durationSec * 1000;
    final pos = ready ? c!.value.position.inMilliseconds : 0;
    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ClipOval(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, child) => Container(
                  width: s - 8,
                  height: s - 8,
                  // Пока идёт передача, фон мягко «дышит».
                  color: Color.lerp(Colors.black87, Colors.blueGrey.shade800, _pulse.value * 0.7),
                  child: child,
                ),
                child: ready
                    ? FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: c!.value.size.width,
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
              child: _working
                  // Передача: известная доля — полоса по кругу, иначе дуга бежит.
                  ? TweenAnimationBuilder<double?>(
                      tween: Tween<double?>(end: widget.progress),
                      duration: const Duration(milliseconds: 300),
                      builder: (_, v, __) => CircularProgressIndicator(
                        value: v,
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    )
                  : CircularProgressIndicator(
                      value: total <= 0 ? 0 : (pos / total).clamp(0.0, 1.0),
                      strokeWidth: 3,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
            ),
            // Значок меняется плавно: «играть» ⇄ облако передачи.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _working
                  ? Icon(widget.busy ? Icons.cloud_sync_outlined : Icons.downloading, key: const ValueKey('work'), size: 40, color: Colors.white70)
                  : (!playing
                      ? const Icon(Icons.play_circle_fill, key: ValueKey('play'), size: 52, color: Colors.white70)
                      : const SizedBox.shrink(key: ValueKey('none'))),
            ),
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
