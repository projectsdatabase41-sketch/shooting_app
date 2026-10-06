import 'dart:math' as math;
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

/// Контраст двух цветов по WCAG 2.x (1..21): 4.5 — норма для обычного
/// текста, 3 — для крупного и значков.
double contrastRatio(Color a, Color b) {
  double lin(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) =>
      0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  final la = lum(a), lb = lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// [preferred] на фоне [bg], если читается (контраст ≥ [min]); иначе — [fallback]
/// (если он читается), иначе чёрный или белый, смотря что контрастнее.
/// Нужно, чтобы пользовательские и готовые цвета не давали «синий текст на
/// синем».
Color readableOn(Color bg, Color preferred,
    {Color? fallback, double min = 4.5}) {
  if (contrastRatio(bg, preferred) >= min) return preferred;
  if (fallback != null && contrastRatio(bg, fallback) >= min) return fallback;
  const black = Color(0xFF000000), white = Color(0xFFFFFFFF);
  return contrastRatio(bg, black) >= contrastRatio(bg, white) ? black : white;
}
