import 'dart:async';
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
  const VoicePlayerBar({super.key, required this.durationSec, required this.fg, required this.load});

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
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: fg,
                inactiveTrackColor: fg.withValues(alpha: 0.3),
                thumbColor: fg,
              ),
              child: Slider(
                value: total <= 0 ? 0 : (_pos.inMilliseconds / total).clamp(0.0, 1.0),
                onChanged: _source == null || total <= 0
                    ? null
                    : (v) => _player?.seek(Duration(milliseconds: (v * total).round())),
              ),
            ),
          ),
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
