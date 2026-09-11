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
    final trimmed = nickname.trim();
    final letter = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    return CircleAvatar(radius: radius, child: Text(letter));
  }
}
