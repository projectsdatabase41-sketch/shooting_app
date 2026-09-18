import 'package:flutter/material.dart';

/// Готовое сочетание фона приложения + цвета кнопок + цвета текста на
/// кнопках — заполняет все три сразу (решение пользователя: "пресетов
/// для меню"), тот же приём, что `ColorPreset` у мишени и
/// `ChatBubblePreset` у чата.
class AppColorPreset {
  final String label;
  final Color background;
  final Color button;
  final Color buttonText;

  const AppColorPreset({
    required this.label,
    required this.background,
    required this.button,
    required this.buttonText,
  });
}

const List<AppColorPreset> appColorPresets = [
  AppColorPreset(
    label: 'Графит',
    background: Color(0xFF11161B),
    button: Color(0xFF2C4A63),
    buttonText: Color(0xFFFFFFFF),
  ),
  AppColorPreset(
    label: 'Хаки',
    background: Color(0xFF1B1D16),
    button: Color(0xFF4B5320),
    buttonText: Color(0xFFEDEAE0),
  ),
  AppColorPreset(
    // Раньше карточки/кнопки были шоколадно-коричневыми (0xFF2B211B) —
    // по отзыву на скриншот рабочего экрана это читалось как "коричневые
    // карточки", а не техничный тёмный интерфейс. Заменено на
    // серо-графитовый нейтральный тон (тот же принцип, что и фон), тёплый
    // золотой акцент — оставлен, он и был единственной сильной стороной.
    label: 'Ночь',
    background: Color(0xFF0B0F13),
    button: Color(0xFF34302B),
    buttonText: Color(0xFFD9A855),
  ),
  AppColorPreset(
    label: 'Кофе',
    background: Color(0xFF1B140F),
    button: Color(0xFF6F4E37),
    buttonText: Color(0xFFF3E5D8),
  ),
  AppColorPreset(
    label: 'Светлый',
    background: Color(0xFFF6F8FA),
    button: Color(0xFF2C4A63),
    buttonText: Color(0xFFFFFFFF),
  ),
  AppColorPreset(
    label: 'Мята',
    background: Color(0xFF11201C),
    button: Color(0xFF3E8E7E),
    buttonText: Color(0xFFEAFBF6),
  ),
];
