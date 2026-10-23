import 'dart:async';

import 'package:flutter/foundation.dart';

/// Кричалки зрителей: короткие реакции, которые видят все в финале.
class CheerFeed extends ChangeNotifier {
  /// Вид → (значок, что произносит диктор у ведущего).
  static const kinds = <String, (String, String)>{
    'clap': ('👏', 'Браво!'),
    'fire': ('🔥', 'Жми!'),
    'power': ('💪', 'Давай!'),
    'aim': ('🎯', 'В десятку!'),
    'cup': ('🏆', 'Чемпион!'),
  };

  /// Как долго реакция висит на экране.
  static const lifetime = Duration(seconds: 4);

  final List<({String name, String kind, DateTime at})> items = [];
  bool _disposed = false;

  void add(String name, String kind) {
    if (!kinds.containsKey(kind) || _disposed) return;
    items.add((name: name, kind: kind, at: DateTime.now()));
    if (items.length > 6) items.removeAt(0);
    notifyListeners();
    Timer(lifetime + const Duration(milliseconds: 50), () {
      if (_disposed) return;
      items.removeWhere((i) => DateTime.now().difference(i.at) >= lifetime);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
