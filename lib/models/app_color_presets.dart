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

  /// Для тёмной темы (иначе — для светлой). Пресеты чужой темы не показываются.
  final bool dark;

  /// Создан пользователем (можно удалить).
  final bool custom;

  const AppColorPreset({
    required this.label,
    required this.background,
    required this.button,
    required this.buttonText,
    this.dark = true,
    this.custom = false,
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
    label: 'Мята',
    background: Color(0xFF11201C),
    button: Color(0xFF3E8E7E),
    buttonText: Color(0xFFEAFBF6),
  ),
  // --- Светлая тема ---
  AppColorPreset(
    label: 'Светлый',
    background: Color(0xFFF6F8FA),
    button: Color(0xFF2C4A63),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
  AppColorPreset(
    label: 'Песок',
    background: Color(0xFFF7F1E6),
    button: Color(0xFF8A5A2B),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
  AppColorPreset(
    label: 'Небо',
    background: Color(0xFFEFF5FB),
    button: Color(0xFF1F6FB2),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
  AppColorPreset(
    label: 'Шалфей',
    background: Color(0xFFF1F5F0),
    button: Color(0xFF4F7A5A),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
  AppColorPreset(
    label: 'Лаванда',
    background: Color(0xFFF5F3FA),
    button: Color(0xFF6A55A3),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
  AppColorPreset(
    label: 'Мишень',
    background: Color(0xFFFAFAF7),
    button: Color(0xFFC62828),
    buttonText: Color(0xFFFFFFFF),
    dark: false,
  ),
];
