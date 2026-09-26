import 'dart:convert';

import 'package:flutter/material.dart';

/// Круглый аватар из base64 JPEG (см. `AvatarUtils`) — плейсхолдер с
/// первой буквой никнейма, если фото нет.
class ChatAvatar extends StatelessWidget {
  final String? base64;
  final String nickname;
  final double radius;

  /// Цвет фона без фото (у групп — выбранный цвет группы).
  final Color? background;

  /// Зелёная точка «в сети» (друзья, см. ChatPresence).
  final bool online;

  const ChatAvatar(
      {super.key, required this.base64, required this.nickname, this.radius = 20, this.background, this.online = false});

  /// Декодированные фото — чтобы аватар не перегружался (и не мигал) на каждой перестройке.
  static final Map<String, MemoryImage> _cache = {};

  @override
  Widget build(BuildContext context) {
    final avatar = _avatar();
    if (!online) return avatar;
    final d = (radius * 0.55).clamp(9.0, 16.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              color: const Color(0xFF3DDC84),
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatar() {
    final b64 = base64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        if (_cache.length > 200) _cache.clear();
        final img = _cache[b64] ??= MemoryImage(base64Decode(b64));
        return CircleAvatar(radius: radius, backgroundImage: img);
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
      backgroundColor: background ?? HSLColor.fromAHSL(1, hue, 0.45, 0.42).toColor(),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: radius * 0.75)),
    );
  }
}

/// Цвет группы из hex ('#RRGGBB'); пусто или мусор — null.
Color? chatGroupColor(String hex) {
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Цвет подписи автора в группе — стабильный по id, как у инициалов.
Color chatSenderColor(String id) =>
    HSLColor.fromAHSL(1, (id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xFFFF) % 360).toDouble(), 0.6, 0.62)
        .toColor();
