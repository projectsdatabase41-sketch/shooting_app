import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/color_presets.dart';
import 'package:shooting_app/models/target_color_scheme.dart';

void main() {
  group('TargetColorScheme — дефолты (A.1)', () {
    test('classic пресет совпадает с default для всех 15 ключей', () {
      for (final key in TargetColorScheme.allKeys) {
        expect(TargetColorScheme.classic[key].toARGB32(), TargetColorScheme.defaultScheme[key].toARGB32());
      }
    });

    test('ровно 15 ключей', () {
      expect(TargetColorScheme.allKeys.length, 15);
    });

    test('isDefault отражает совпадение с classic', () {
      const scheme = TargetColorScheme.defaultScheme;
      for (final key in TargetColorScheme.allKeys) {
        expect(scheme.isDefault(key), isTrue);
      }
      final changed = scheme.copyWithKey('shot_selected', const Color(0xFF123456));
      expect(changed.isDefault('shot_selected'), isFalse);
      expect(changed.isDefault('target_paper'), isTrue);
    });
  });

  group('HEX <-> Color', () {
    test('round-trip #RRGGBB', () {
      const hex = '#B0BEC5';
      final color = TargetColorScheme.hexToColor(hex);
      expect(TargetColorScheme.colorToHex(color, withAlpha: false), hex);
    });

    test('невалидный HEX -> isValidHex=false', () {
      expect(TargetColorScheme.isValidHex('не-цвет'), isFalse);
      expect(TargetColorScheme.isValidHex('#ZZZZZZ'), isFalse);
      expect(TargetColorScheme.isValidHex('#B0BEC5'), isTrue);
    });
  });

  group('Пресеты (A.2.1)', () {
    test('7 именованных пресетов', () {
      expect(ColorPresets.all.length, 7);
    });

    test('activeFor находит "Классическая" для дефолтной схемы', () {
      final active = ColorPresets.activeFor(TargetColorScheme.defaultScheme);
      expect(active?.name, 'Классическая');
    });

    test('после точечного изменения ни одна карточка не активна', () {
      final changed = TargetColorScheme.defaultScheme.copyWithKey('crosshair', const Color(0xFF000000));
      expect(ColorPresets.activeFor(changed), isNull);
    });

    test('каждый пресет — полный набор из 15 значений, отличный (хотя бы частично) от других', () {
      final signatures = ColorPresets.all.map((p) => TargetColorScheme.allKeys.map((k) => p.scheme[k].toARGB32()).join(',')).toSet();
      expect(signatures.length, ColorPresets.all.length); // все 7 уникальны
    });
  });

  group('Экспорт/импорт (A.2.2)', () {
    test('round-trip: экспорт -> импорт даёт идентичный набор значений', () {
      final original = TargetColorScheme.defaultScheme.copyWithKey('shot_selected', const Color(0xFF112233));
      final json = ColorSchemeIo.exportToJson(original);
      final imported = ColorSchemeIo.importFromJson(json, TargetColorScheme.defaultScheme);
      expect(imported.sameColorsAs(original), isTrue);
    });

    test('битый HEX в одном ключе -> импорт отклоняется целиком (all-or-nothing)', () {
      const badJson = '{"target_paper": "#XYZXYZ", "crosshair": "#FF0000"}';
      expect(
        () => ColorSchemeIo.importFromJson(badJson, TargetColorScheme.defaultScheme),
        throwsA(isA<FormatException>()),
      );
    });

    test('неизвестные ключи молча игнорируются', () {
      const json = '{"unknown_future_key": "#FF0000", "crosshair": "#00FF00"}';
      final imported = ColorSchemeIo.importFromJson(json, TargetColorScheme.defaultScheme);
      expect(imported.crosshair.toARGB32(), const Color(0xFF00FF00).toARGB32());
    });

    test('ключи, отсутствующие в файле, не сбрасываются', () {
      final base = TargetColorScheme.defaultScheme.copyWithKey('shot_selected', const Color(0xFFAA00AA));
      const json = '{"crosshair": "#00FF00"}';
      final imported = ColorSchemeIo.importFromJson(json, base);
      expect(imported.shotSelected.toARGB32(), const Color(0xFFAA00AA).toARGB32());
    });
  });
}
