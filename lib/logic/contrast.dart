import 'dart:ui' show Color;

/// Автоконтраст номера выстрела (часть A.4 логики-спека).
///
/// luminance > 0.5 → тёмный текст (#212121), иначе → светлый (#FFFFFF).
const Color kAutoContrastDark = Color(0xFF212121);
const Color kAutoContrastLight = Color(0xFFFFFFFF);

/// Относительная яркость по формуле стандартной luminance (упрощённая,
/// без гамма-коррекции sRGB — этого достаточно для UI-контраста, точная
/// WCAG-формула здесь избыточна).
double relativeLuminance(Color color) {
  // .r/.g/.b — современные float-компоненты Color (0.0..1.0), уже в
  // нужном масштабе для формулы, деление на 255 не требуется.
  return 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
}

Color autoContrastTextColor(Color backgroundColor) {
  return relativeLuminance(backgroundColor) > 0.5
      ? kAutoContrastDark
      : kAutoContrastLight;
}
