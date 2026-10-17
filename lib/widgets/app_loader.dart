import 'package:flutter/material.dart';

import 'splash_gate.dart';

/// Анимация ожидания: пульсирующая N в круге (как заставка) вместо колеса
/// загрузки. Видео не используется — работает одинаково в вебе и в тестах.
class AppLoader extends StatelessWidget {
  /// Размер индикатора; под доступное место подгоняется сам.
  final double width;
  const AppLoader({super.key, this.width = 150});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final maxSide = [width, box.maxWidth.isFinite ? box.maxWidth : width, box.maxHeight.isFinite ? box.maxHeight : width]
            .reduce((a, b) => a < b ? a : b);
        return NexusPulse(size: maxSide < 24 ? 24 : maxSide);
      });
}
