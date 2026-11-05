import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/chat_media_utils.dart';
import 'voice_bubble.dart' show MediaSource, formatClock;

/// Аудиофайл в переписке — маленький плеер вместо ярлыка «этот тип файла
/// нельзя показать» (отзыв от 02.11.2026: присланный mp3 не открывался).
///
/// Играет прямо в пузыре: play/pause, −10 c / +10 c, полоса позиции,
/// время. В углу — «скачать» (файл уходит в «Загрузки»/Nexus и виден в
/// системе устройства). Тап по названию открывает полноэкранный плеер
/// со скоростью и слайдером — для длинных записей.
///
/// Файл с сервера при первом нажатии скачивается незаметно ([load]):
/// тот же приём, что у голосовых сообщений.
class AudioFileBubble extends StatefulWidget {
  final String name;
  final int? size;
  final Color fg;

  /// Своё сообщение (чужие пузыри и свои отличаются цветом текста).
  final bool mine;

  /// Файл ещё лежит только на сервере.
  final bool remote;

  /// Прямо сейчас скачивается большой файл (показываем «крутилку»).
  final bool busy;

  final Future<MediaSource?> Function() load;

  /// «Скачать»: null — кнопка не показывается.
  final VoidCallback? onSave;
  final bool saved;

  /// Открыть полноэкранный плеер.
  final VoidCallback onOpenFull;

  const AudioFileBubble({
    super.key,
    required this.name,
    required this.size,
    required this.fg,
    required this.mine,
    required this.load,
    required this.onOpenFull,
    this.remote = false,
    this.busy = false,
    this.onSave,
    this.saved = false,
  });

  @override
  State<AudioFileBubble> createState() => _AudioFileBubbleState();
}

class _AudioFileBubbleState extends State<AudioFileBubble> {
  /// Играет что-то одно: два голоса одновременно — это не плеер, а ссора.
  static _AudioFileBubbleState? _active;

  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _playing = false;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;
  double _speed = 1;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    if (_active == this) _active = null;
    super.dispose();
  }

  void _pauseByOther() {
    if (!_playing) return;
    _player?.pause();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player?.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (_player == null) {
      setState(() => _loading = true);
      try {
        final src = await widget.load();
        if (!mounted) return;
        if (src == null) {
          setState(() => _loading = false);
          _fail();
          return;
        }
        final pl = AudioPlayer();
        _player = pl;
        _subs
          ..add(pl.onPositionChanged.listen((d) {
            if (mounted) setState(() => _pos = d);
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
        if (_speed != 1) await pl.setPlaybackRate(_speed);
      } catch (_) {
        if (mounted) setState(() => _loading = false);
        _fail();
        return;
      }
      if (!mounted) return;
      setState(() => _loading = false);
    }
    _active?._pauseByOther();
    _active = this;
    try {
      await _player!.resume();
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(SnackBar(content: Text(tr('Не удалось воспроизвести запись'))));
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

  Future<void> _seekTo(Duration d) async {
    final pl = _player;
    if (pl == null) return;
    await pl.seek(d);
    if (mounted) setState(() => _pos = d);
  }

  /// Доля проигранного 0…1 для полосы (у неизвестной длительности — 0).
  double get _progress {
    if (_total.inMilliseconds <= 0) return 0;
    return (_pos.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = widget.fg;
    final sub = fg.withValues(alpha: 0.75);
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        // Своя подложка: плеер должен читаться и на светлом, и на тёмном пузыре.
        color: fg.withValues(alpha: widget.mine ? 0.10 : 0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RoundButton(
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_playing ? Icons.pause : Icons.play_arrow, size: 26),
                fg: fg,
                onTap: widget.busy ? null : _toggle,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onOpenFull,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: fg, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.size == null
                            ? formatClock(_total.inSeconds)
                            : '${formatClock(_total.inSeconds)} · ${ChatMediaUtils.formatSize(widget.size!)}',
                        style: theme.textTheme.labelSmall?.copyWith(color: sub),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.onSave != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                  tooltip: widget.saved ? tr('Уже скачано') : tr('Скачать'),
                  onPressed: widget.saved ? null : widget.onSave,
                  icon: Icon(
                      widget.saved ? Icons.download_done : Icons.download_outlined,
                      size: 20,
                      color: widget.saved ? sub : fg),
                ),
            ],
          ),
          const SizedBox(height: 2),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: fg,
              inactiveTrackColor: fg.withValues(alpha: 0.25),
              thumbColor: fg,
            ),
            child: Slider(
              value: _progress,
              // Полоса работает только когда файл уже открыт плеером:
              // тащить её до загрузки некуда.
              onChanged: _player == null ? null : (v) {},
              onChangeEnd: _player == null
                  ? null
                  : (v) => _seekTo(Duration(
                      milliseconds:
                          (v * _total.inMilliseconds).round().clamp(0, 1 << 31))),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SmallIcon(
                  icon: Icons.replay_10,
                  fg: fg,
                  tip: tr('Назад 10 секунд'),
                  onTap: () => _seekBy(-10)),
              Text('${formatClock(_pos.inSeconds)} / ${formatClock(_total.inSeconds)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: sub)),
              _SmallIcon(
                  icon: Icons.forward_10,
                  fg: fg,
                  tip: tr('Вперёд 10 секунд'),
                  onTap: () => _seekBy(10)),
              _SmallIcon(
                  icon: Icons.open_in_full,
                  fg: fg,
                  tip: tr('Открыть в плеере'),
                  onTap: widget.onOpenFull),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final Widget icon;
  final Color fg;
  final VoidCallback? onTap;
  const _RoundButton({required this.icon, required this.fg, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 24,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fg.withValues(alpha: 0.16),
        ),
        child: IconTheme(data: IconThemeData(color: fg), child: icon),
      ),
    );
  }
}

class _SmallIcon extends StatelessWidget {
  final IconData icon;
  final Color fg;
  final String tip;
  final VoidCallback onTap;
  const _SmallIcon(
      {required this.icon, required this.fg, required this.tip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 20, color: fg),
        ),
      ),
    );
  }
}
