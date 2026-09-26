import 'dart:async';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

/// Прогрев шрифта смайликов при открытии мессенджера: браузер скачивает
/// шрифт эмодзи кусками только когда видит нужный символ, и без прогрева
/// панель смайликов сначала показывала одинаковые квадратики. Рисуем
/// невидимо (клетка 1×1) по одной категории раз в 0,7 с — пакетами, чтобы
/// не подвешивать экран. Один раз за запуск приложения.
class EmojiWarmup extends StatefulWidget {
  const EmojiWarmup({super.key});

  @override
  State<EmojiWarmup> createState() => _EmojiWarmupState();
}

class _EmojiWarmupState extends State<EmojiWarmup> {
  static bool _done = false;
  int _category = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_done) return;
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (_category + 1 >= defaultEmojiSet.length) {
        _done = true;
        _timer?.cancel();
      }
      if (mounted) setState(() => _category++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done || _category >= defaultEmojiSet.length) return const SizedBox.shrink();
    final text = defaultEmojiSet[_category].emoji.map((e) => e.emoji).join();
    return IgnorePointer(
      child: SizedBox(
        width: 1,
        height: 1,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            maxWidth: 4000,
            maxHeight: 4000,
            child: Text(text, style: const TextStyle(fontSize: 12, color: Color(0x01000000))),
          ),
        ),
      ),
    );
  }
}
