import 'dart:convert';

import 'package:flutter/material.dart';

/// Круглый аватар из base64 JPEG (см. `AvatarUtils`) — плейсхолдер с
/// первой буквой никнейма, если фото нет.
class ChatAvatar extends StatelessWidget {
  final String? base64;
  final String nickname;
  final double radius;

  const ChatAvatar({super.key, required this.base64, required this.nickname, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final b64 = base64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return CircleAvatar(radius: radius, backgroundImage: MemoryImage(base64Decode(b64)));
      } catch (_) {
        // битые данные — падаем на плейсхолдер ниже
      }
    }
    // Без фото — инициалы на цвете, зависящем от ника: тёзок-без-фото
    // всё равно отличить проще, чем по одинаковым серым кружкам.
    final words = nickname.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0].toUpperCase()).join();
    final hue = (nickname.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xFFFF) % 360).toDouble();
    return CircleAvatar(
      radius: radius,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.45, 0.42).toColor(),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: radius * 0.75)),
    );
  }
}
