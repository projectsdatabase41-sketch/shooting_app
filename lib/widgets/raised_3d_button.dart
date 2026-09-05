import 'package:flutter/material.dart';

/// Кнопка с объёмным ("3D") нажатием: заливка-градиент "сверху светлее"
/// плюс тень снизу, имитирующие выпуклость; при нажатии тень уменьшается,
/// а сама кнопка сдвигается вниз — как будто её вдавили. Без внешних
/// пакетов: только `AnimatedContainer` и `GestureDetector`.
///
/// Общий виджет для кнопок, которым решено придать этот эффект (решение
/// пользователя — "добавь больше 3D эффектов кнопкам") — не копия ради
/// каждого экрана: у мишени, в чате ассистента и в панели управления
/// тренировкой должна быть одна и та же физика нажатия.
class Raised3DButton extends StatefulWidget {
  final IconData? icon;
  final String label;
  final Color baseColor;
  final VoidCallback? onTap;

  /// Компактный размер — для мест с меньшим запасом места (например,
  /// полоса управления тренировкой рядом с таймерами).
  final bool dense;

  const Raised3DButton({
    super.key,
    required this.label,
    required this.baseColor,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  @override
  State<Raised3DButton> createState() => _Raised3DButtonState();
}

class _Raised3DButtonState extends State<Raised3DButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = widget.baseColor;
    final icon = widget.icon;

    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _pressed ? (widget.dense ? 2 : 3) : 0, 0),
        padding: widget.dense
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 9)
            : const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.dense ? 12 : 18),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: enabled
                ? [color.withValues(alpha: 0.95), color.withValues(alpha: 0.70)]
                : [color.withValues(alpha: 0.35), color.withValues(alpha: 0.22)],
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: _pressed ? 0.12 : 0.32),
                    offset: Offset(0, _pressed ? 1 : (widget.dense ? 3 : 5)),
                    blurRadius: _pressed ? 2 : (widget.dense ? 5 : 7),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: widget.dense ? 18 : 24),
              SizedBox(height: widget.dense ? 1 : 3),
            ],
            Text(
              widget.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: widget.dense ? 12 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
