import 'package:flutter/material.dart';

/// Уровень связи с собеседником (как «палочки» сотовой сети):
/// 0 — не в сети; 1 — сообщения только через опрос базы раз в N секунд;
/// 2 — собеседник в сети (по отметке на сервере), но живого канала нет;
/// 3 — живой канал через сервер; 4 — прямое соединение между устройствами.
int linkLevel(
        {required bool direct, required bool live, required bool online}) =>
    direct
        ? 4
        : live
            ? 3
            : online
                ? 2
                : 0;

class LinkSignal extends StatelessWidget {
  final int level;
  const LinkSignal({super.key, required this.level});

  static String describe(int level) => switch (level) {
        4 => 'Прямая связь между устройствами',
        3 => 'Живой канал через сервер',
        2 => 'В сети, сообщения через опрос базы',
        _ => 'Не в сети',
      };

  @override
  Widget build(BuildContext context) {
    final on = switch (level) {
      4 => const Color(0xFF3DDC84),
      3 => const Color(0xFF8BC34A),
      2 => const Color(0xFFFFB300),
      _ => Theme.of(context).hintColor,
    };
    final off = Theme.of(context).hintColor.withValues(alpha: 0.3);
    return Tooltip(
      message: describe(level),
      child: SizedBox(
        width: 18,
        height: 16,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 1; i <= 4; i++) ...[
              Container(
                width: 3,
                height: 4.0 + i * 3,
                decoration: BoxDecoration(
                  color: i <= (level == 0 ? 0 : level) ? on : off,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              if (i < 4) const SizedBox(width: 1.5),
            ],
          ],
        ),
      ),
    );
  }
}
