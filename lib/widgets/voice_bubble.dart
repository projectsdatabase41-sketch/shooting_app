import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Источник медиа вложения: байты (небольшое, лежит в базе) либо файл на диске.
class MediaSource {
  final Uint8List? bytes;
  final String? path;
  final String mime;
  const MediaSource({this.bytes, this.path, required this.mime});
}

/// «m:ss» из секунд.
String formatClock(int seconds) {
  final m = seconds ~/ 60, s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Голосовое сообщение в пузыре: кнопка play/pause, полоса перемотки,
/// время и скорость 1×/1.5×/2×. Файл с сервера при первом нажатии
/// скачивается незаметно ([load]), дальше только воспроизводится.
class VoicePlayerBar extends StatefulWidget {
  final int durationSec;
  final Color fg;
  final Future<MediaSource?> Function() load;

  /// Для рисунка волны: у разных сообщений она разная (например, id сообщения).
  final String seed;

  /// Настоящая огибающая громкости записи (hex 0–f); пусто — волна по умолчанию.
  final String wave;
  const VoicePlayerBar({super.key, required this.durationSec, required this.fg, required this.load, this.seed = '', this.wave = ''});

  @override
  State<VoicePlayerBar> createState() => _VoicePlayerBarState();
}

class _VoicePlayerBarState extends State<VoicePlayerBar> {
  static _VoicePlayerBarState? _active;

  AudioPlayer? _player;
  MediaSource? _source;
  bool _loading = false;
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration? _total;
  double _speed = 1;
  double? _drag; // доля 0…1, пока палец ведёт по волне (позицию плеера не слушаем)
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    if (_active == this) _active = null;
    super.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final pl = AudioPlayer();
    _player = pl;
    _subs
      ..add(pl.onPositionChanged.listen((d) {
        if (mounted) setState(() => _pos = d);
      }))
      ..add(pl.onDurationChanged.listen((d) {
        if (mounted) setState(() => _total = d);
      }))
      ..add(pl.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playing = s == PlayerState.playing);
      }))
      ..add(pl.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _pos = Duration.zero);
      }));
    return pl;
  }

  Source _toSource(MediaSource s) => s.bytes != null
      ? BytesSource(s.bytes!, mimeType: s.mime)
      : DeviceFileSource(s.path!, mimeType: s.mime);

  Future<void> _toggle() async {
    if (_loading) return;
    final pl = _ensurePlayer();
    if (_playing) {
      await pl.pause();
      return;
    }
    // Одновременно играет только одно голосовое.
    if (_active != null && _active != this) await _active!._player?.pause();
    _active = this;
    if (_source == null) {
      setState(() => _loading = true);
      try {
        _source = await widget.load();
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      if (_source == null) return;
      await pl.setPlaybackRate(_speed);
      await pl.play(_toSource(_source!));
    } else {
      await pl.resume();
    }
  }

  Future<void> _cycleSpeed() async {
    final next = _speed == 1 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
    setState(() => _speed = next);
    await _player?.setPlaybackRate(next);
  }

  void _seekTo(double frac, int total) {
    if (_source == null || total <= 0) return;
    _player?.seek(Duration(milliseconds: (frac.clamp(0.0, 1.0) * total).round()));
  }

  /// Волна как в Telegram: столбики, проигранная часть закрашена; тап и
  /// перетаскивание перематывают без «зависающего» ползунка.
  Widget _wave(Color fg, int total) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final progress = total <= 0 ? 0.0 : (_pos.inMilliseconds / total).clamp(0.0, 1.0);
      double frac(double dx) => (dx / w).clamp(0.0, 1.0);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _seekTo(frac(d.localPosition.dx), total),
        onHorizontalDragStart: (d) => setState(() => _drag = frac(d.localPosition.dx)),
        onHorizontalDragUpdate: (d) => setState(() => _drag = frac(d.localPosition.dx)),
        onHorizontalDragEnd: (_) {
          final f = _drag;
          setState(() => _drag = null);
          if (f != null) _seekTo(f, total);
        },
        onHorizontalDragCancel: () => setState(() => _drag = null),
        child: SizedBox(
          height: 32,
          child: CustomPaint(
            size: Size(w, 32),
            painter: _WavePainter(
              seed: Object.hash(widget.seed, widget.durationSec),
              wave: widget.wave,
              progress: _drag ?? progress,
              played: fg,
              rest: fg.withValues(alpha: 0.35),
              active: _playing,
            ),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.fg;
    final total = (_total ?? Duration(seconds: widget.durationSec)).inMilliseconds;
    final shown = _playing || _pos > Duration.zero ? _pos : Duration(seconds: widget.durationSec);
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          InkResponse(
            onTap: _toggle,
            radius: 24,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: fg.withValues(alpha: 0.18)),
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(_playing ? Icons.pause : Icons.play_arrow, color: fg),
            ),
          ),
          Expanded(child: _wave(fg, total)),
          Text(formatClock(shown.inSeconds), style: TextStyle(color: fg, fontSize: 12)),
          const SizedBox(width: 6),
          InkWell(
            onTap: _cycleSpeed,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(_speed == 1 ? '1×' : (_speed == 1.5 ? '1.5×' : '2×'),
                  style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final int seed;
  final double progress;
  final Color played;
  final Color rest;
  final bool active;
  final String wave;
  _WavePainter({required this.seed, required this.progress, required this.played, required this.rest, required this.active, this.wave = ''});

  @override
  void paint(Canvas canvas, Size size) {
    const bar = 3.0, gap = 2.0;
    final n = math.max(8, (size.width / (bar + gap)).floor());
    final rnd = math.Random(seed);
    final paint = Paint()..strokeCap = StrokeCap.round..strokeWidth = bar;
    for (var i = 0; i < n; i++) {
      // Плавные «речевые» столбики: огибающая и случайность.
      double h;
      if (wave.isNotEmpty) {
        // Реальная громкость: берём ближайшее значение огибающей.
        final v = int.tryParse(wave[(i * wave.length / n).floor().clamp(0, wave.length - 1)], radix: 16) ?? 4;
        h = size.height * (0.14 + 0.86 * v / 15);
      } else {
        final env = 0.45 + 0.55 * math.sin(i / n * math.pi);
        h = size.height * (0.25 + 0.75 * rnd.nextDouble()) * env;
      }
      final x = i * (bar + gap) + bar / 2;
      final done = (i + 0.5) / n <= progress;
      // Столбик под проигрываемой позицией чуть «пульсирует».
      if (active && ((i + 0.5) / n - progress).abs() < 0.04) h = math.min(size.height, h * 1.25);
      paint.color = done ? played : rest;
      final cy = size.height / 2;
      canvas.drawLine(Offset(x, cy - h / 2), Offset(x, cy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress || old.active != active || old.played != played || old.wave != wave;
}
