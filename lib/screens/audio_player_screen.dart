import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/chat_media_utils.dart';
import '../widgets/voice_bubble.dart' show MediaSource, formatClock;

/// Полноэкранный плеер для длинной записи из переписки.
///
/// Открывается тапом по названию файла в мини-плеере пузыря. Тёмное окно
/// поверх чата (в тон остальным просмотрщикам вложений): название, слайдер
/// позиции, ±10 секунд, play/pause и скорость 0.5×…2×.
class AudioPlayerScreen extends StatefulWidget {
  final String name;
  final int? size;
  final Future<MediaSource?> Function() load;

  /// Позиция, на которой остановился мини-плеер в пузыре.
  final Duration startAt;

  const AudioPlayerScreen({
    super.key,
    required this.name,
    required this.load,
    this.size,
    this.startAt = Duration.zero,
  });

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  bool _loading = true;
  String? _error;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  double _speed = 1;
  bool _dragging = false;

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final src = await widget.load();
      if (!mounted) return;
      if (src == null) {
        setState(() {
          _loading = false;
          _error = tr('Не удалось получить файл');
        });
        return;
      }
      final pl = AudioPlayer();
      _player = pl;
      _subs
        ..add(pl.onPositionChanged.listen((d) {
          if (mounted && !_dragging) setState(() => _pos = d);
        }))
        ..add(pl.onDurationChanged.listen((d) {
          if (mounted) setState(() => _total = d);
        }))
        ..add(pl.onPlayerComplete.listen((_) {
          if (mounted) {
            setState(() {
              _playing = false;
              _pos = Duration.zero;
            });
          }
        }));
      if (src.bytes != null) {
        await pl.setSource(BytesSource(src.bytes!, mimeType: src.mime));
      } else if (src.path != null) {
        await pl.setSource(DeviceFileSource(src.path!));
      }
      if (widget.startAt > Duration.zero) await pl.seek(widget.startAt);
      await pl.setPlaybackRate(_speed);
      await pl.resume();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = tr('Не удалось воспроизвести запись');
        });
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final pl = _player;
    if (pl == null) return;
    if (_playing) {
      await pl.pause();
      setState(() => _playing = false);
    } else {
      await pl.resume();
      setState(() => _playing = true);
    }
  }

  Future<void> _seekBy(int seconds) async {
    final pl = _player;
    if (pl == null) return;
    var target = _pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (_total > Duration.zero && target > _total) target = _total;
    await pl.seek(target);
    if (mounted) setState(() => _pos = target);
  }

  Future<void> _setSpeed(double s) async {
    setState(() => _speed = s);
    await _player?.setPlaybackRate(s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Тёмный фон в тон остальным просмотрщикам: чат под окном не отвлекает.
    const bg = Color(0xF2101214);
    final max = _total.inMilliseconds.toDouble();
    final value = max <= 0 ? 0.0 : _pos.inMilliseconds.clamp(0, _total.inMilliseconds).toDouble();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                ),
                child: Icon(Icons.graphic_eq, size: 56, color: Colors.white.withValues(alpha: 0.85)),
              ),
              const SizedBox(height: 20),
              Text(widget.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
              if (widget.size != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(ChatMediaUtils.formatSize(widget.size!),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white70)),
                ),
              const SizedBox(height: 28),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.white70))
              else if (_loading)
                const CircularProgressIndicator()
              else ...[
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbColor: Colors.white,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: value,
                    max: max <= 0 ? 1 : max,
                    onChangeStart: (_) => setState(() => _dragging = true),
                    onChanged: (v) =>
                        setState(() => _pos = Duration(milliseconds: v.round())),
                    onChangeEnd: (v) async {
                      await _player?.seek(Duration(milliseconds: v.round()));
                      if (mounted) setState(() => _dragging = false);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(formatClock(_pos.inSeconds),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(formatClock(_total.inSeconds),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      tooltip: tr('Назад 10 секунд'),
                      onPressed: () => _seekBy(-10),
                      icon: const Icon(Icons.replay_10),
                    ),
                    const SizedBox(width: 12),
                    InkResponse(
                      onTap: _toggle,
                      radius: 40,
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Colors.white),
                        child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                            size: 40, color: Colors.black),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      tooltip: tr('Вперёд 10 секунд'),
                      onPressed: () => _seekBy(10),
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Скорость — «пилюлями», как в подкаст-плеерах.
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final s in _speeds)
                      ChoiceChip(
                        label: Text('${s.toString().replaceAll('.0', '')}×'),
                        selected: _speed == s,
                        onSelected: (_) => _setSpeed(s),
                        selectedColor: Colors.white,
                        backgroundColor: Colors.white12,
                        labelStyle: TextStyle(
                            color: _speed == s ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w600),
                        side: BorderSide.none,
                      ),
                  ],
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
