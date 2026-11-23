import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Индикатор записи голосового сообщения — перенос состояния записи из
/// промпта voice-input.tsx (Desktop\Запись голосового сообщения.txt):
/// квадрат вращается 0→360° за 2 с, справа «раскрывается» полоса из
/// 12 вертикальных столбиков частот, ещё правее таймер ММ:СС.
///
/// Раньше в поле ввода чата на месте записи стояли статичная точка и таймер;
/// теперь там этот индикатор (просьба владельца перенести промпт).
///
/// Высота компактная — как у остальной строки ввода (см. вызов в
/// chat_thread_screen.dart): пилюля композера не должна раздуваться.
class VoiceRecordingIndicator extends StatefulWidget {
  /// Идёт запись: квадрат вращается, столбики «дышат».
  final bool recording;

  /// Сколько уже записано. Таймер обновляет снаружи (в чате — Timer на 1 с),
  /// поэтому своих Timer'ов виджет не заводит и утечек не создаёт.
  final Duration elapsed;

  /// Цвет квадрата, столбиков и обводки кнопки (обычно cs.primary).
  final Color color;

  /// Тап по кнопке — как у кнопки записи: останавливает запись (в чате —
  /// отправка; отмена остаётся отдельной кнопкой с крестиком).
  final VoidCallback onTap;

  const VoiceRecordingIndicator({
    super.key,
    required this.recording,
    required this.elapsed,
    required this.color,
    required this.onTap,
  });

  @override
  State<VoiceRecordingIndicator> createState() =>
      _VoiceRecordingIndicatorState();
}

class _VoiceRecordingIndicatorState extends State<VoiceRecordingIndicator>
    with SingleTickerProviderStateMixin {
  /// 12 столбиков «частот», как в промпте.
  static const int _barCount = 12;
  static const double _barMin = 2; // px
  static const double _barMax = 14; // px
  static const double _barWidth = 2;
  static const double _barGap = 1.5;

  /// Полный оборот квадрата — 2 секунды (из промпта), он же цикл столбиков.
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));

  /// Плавный разгон/торможение, как ease "easeInOut" в промпте.
  late final Animation<double> _eased =
      CurvedAnimation(parent: _spin, curve: Curves.easeInOut);

  /// «Уменьшить движение» в системе: кадры не тратим — квадрат не крутится,
  /// столбики стоят (требование задачи; так же ведёт себя остальная анимация).
  /// Кэшируем в didChangeDependencies: в didUpdateWidget/build обращение к
  /// MediaQuery.of не нужно (оно подписывает на изменения и лишне дёргает build).
  bool _reducedMotion = false;

  /// Запускает/останавливает контроллер: без записи и при включённом
  /// «уменьшении движения» анимация не тикает вхолостую.
  void _sync() {
    final run = widget.recording && !_reducedMotion;
    if (!run) {
      // Ставим в ноль только если что-то крутилось: повторная запись value
      // дёргала бы слушателей контроллера на каждом обновлении зависимостей.
      if (_spin.isAnimating || _spin.value != 0) {
        _spin.stop();
        _spin.value = 0;
      }
      return;
    }
    if (!_spin.isAnimating) _spin.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant VoiceRecordingIndicator old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    // Контроллер обязательно освобождаем: иначе его тик живёт после
    // закрытия экрана (утечка, о которой предупреждали в задаче).
    _spin.dispose();
    super.dispose();
  }

  /// ММ:СС, как в промпте: «00:07», а не «0:07».
  static String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final still = _reducedMotion || !widget.recording;
    return AnimatedBuilder(
      animation: _spin,
      builder: (context, _) {
        // В статике берём фазу 0 — столбики остаются на местах и не дёргаются.
        final t = still ? 0.0 : _spin.value;
        final angle = still ? 0.0 : _eased.value * 2 * math.pi;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Кнопка с квадратом. Раньше здесь была статичная красная точка.
            Tooltip(
              message: tr('Остановить запись'),
              child: GestureDetector(
                onTap: widget.onTap,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 15,
                      height: 15,
                      child: Transform.rotate(
                        angle: angle,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.color,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 7),
            // Столбики «частот»: высота 2…14 px, фаза сдвинута по индексу.
            // Синус от времени контроллера, а не Math.random на каждом кадре:
            // на CanvasKit случайные скачки каждый кадр дороже и дёргаются.
            for (var i = 0; i < _barCount; i++) ...[
              SizedBox(
                width: _barWidth,
                height: _barMin +
                    (_barMax - _barMin) *
                        ((math.sin(2 * math.pi * t + i * 0.55) + 1) / 2),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(_barWidth / 2),
                  ),
                ),
              ),
              if (i != _barCount - 1) const SizedBox(width: _barGap),
            ],
            const SizedBox(width: 7),
            // Цифры табличные — таймер не «пляшет» при смене секунд.
            Text(
              _clock(widget.elapsed),
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }
}
