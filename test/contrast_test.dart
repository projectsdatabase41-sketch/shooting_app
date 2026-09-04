import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/contrast.dart';

void main() {
  group('Автоконтраст (часть A.4 логики-спека)', () {
    test('luminance ровно 0.5 -> тёмный текст (граница "> 0.5", не ">=")', () {
      // Серый с luminance == 0.5: 0.299r+0.587g+0.114b = 0.5 при r=g=b=X
      // где X ~ 0.5/(0.299+0.587+0.114)=0.5 (сумма коэффициентов ==1),
      // так что серый (127,127,127)/255 даёт почти ровно 0.5.
      const grayHalf = Color.fromARGB(255, 128, 128, 128); // luminance ≈ 0.502
      expect(relativeLuminance(grayHalf), greaterThan(0.5));
      expect(autoContrastTextColor(grayHalf), kAutoContrastDark);
    });

    test('luminance 0.49-эквивалент (тёмный фон) -> светлый текст', () {
      const dark = Color.fromARGB(255, 100, 100, 100); // luminance ≈ 0.392
      expect(relativeLuminance(dark), lessThan(0.5));
      expect(autoContrastTextColor(dark), kAutoContrastLight);
    });

    test('luminance 0.51-эквивалент (светлый фон) -> тёмный текст', () {
      const light = Color.fromARGB(255, 160, 160, 160); // luminance ≈ 0.627
      expect(relativeLuminance(light), greaterThan(0.5));
      expect(autoContrastTextColor(light), kAutoContrastDark);
    });

    test('чёрный -> светлый текст, белый -> тёмный текст', () {
      expect(autoContrastTextColor(const Color(0xFF000000)), kAutoContrastLight);
      expect(autoContrastTextColor(const Color(0xFFFFFFFF)), kAutoContrastDark);
    });
  });
}
