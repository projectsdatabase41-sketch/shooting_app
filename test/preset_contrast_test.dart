import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/contrast.dart';
import 'package:shooting_app/models/app_color_presets.dart';
import 'package:shooting_app/services/chat_preferences.dart';
import 'package:shooting_app/theme/app_theme.dart';

void main() {
  test('readableOn: синий текст на синем заменяется читаемым', () {
    const blue = Color(0xFF1F6FB2);
    expect(contrastRatio(blue, blue), 1);
    expect(
        contrastRatio(blue, readableOn(blue, blue)), greaterThanOrEqualTo(4.5));
  });

  for (final p in appColorPresets) {
    test('пресет «${p.label}»: кнопки читаются на своём фоне', () {
      final theme = p.dark
          ? AppTheme.dark(
              background: p.background,
              buttonColor: p.button,
              buttonTextColor: p.buttonText)
          : AppTheme.light(
              background: p.background,
              buttonColor: p.button,
              buttonTextColor: p.buttonText);
      Color? fg(ButtonStyle? s) => s?.foregroundColor?.resolve({});
      Color? bg(ButtonStyle? s) => s?.backgroundColor?.resolve({});
      final filled = theme.filledButtonTheme.style;
      expect(contrastRatio(bg(filled)!, fg(filled)!), greaterThanOrEqualTo(4.5),
          reason: 'заливка');
      expect(contrastRatio(p.background, fg(theme.outlinedButtonTheme.style)!),
          greaterThanOrEqualTo(4.5),
          reason: 'контурные');
      expect(contrastRatio(p.background, fg(theme.textButtonTheme.style)!),
          greaterThanOrEqualTo(4.5),
          reason: 'текстовые');
    });
  }

  for (final p in ChatPreferences.presets) {
    test('пузыри чата «${p.label}»: текст читается', () {
      expect(contrastRatio(p.mine, p.mineText), greaterThanOrEqualTo(3.0),
          reason: 'свои');
      expect(contrastRatio(p.other, p.otherText), greaterThanOrEqualTo(3.0),
          reason: 'чужие');
    });
  }
}
