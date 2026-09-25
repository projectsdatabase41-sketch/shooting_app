import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/app_color_presets.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/personalization_view_model.dart';

void main() {
  Future<(LocalDbService, PersonalizationViewModel)> vm() async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    return (db, PersonalizationViewModel(db)..loadFromDb());
  }

  test('пресеты разделены по темам, у каждой темы свой набор цветов', () async {
    final (_, v) = await vm();
    final dark = appColorPresets.firstWhere((p) => p.dark);
    final light = appColorPresets.firstWhere((p) => !p.dark);
    expect(appColorPresets.where((p) => p.dark).every((p) => p.background.computeLuminance() < 0.2), isTrue);
    expect(appColorPresets.where((p) => !p.dark).every((p) => p.background.computeLuminance() > 0.7), isTrue);
    v.applyAppColorPreset(dark);
    v.applyAppColorPreset(light);
    expect(v.appBackgroundFor(Brightness.dark), dark.background);
    expect(v.appBackgroundFor(Brightness.light), light.background);
    v.resetAppColors(Brightness.light);
    expect(v.appBackgroundFor(Brightness.light), isNull);
    expect(v.appBackgroundFor(Brightness.dark), dark.background);
  });

  test('старый общий светлый фон переезжает в светлый набор', () async {
    final (db, _) = await vm();
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('app_bg_color', '#FFF6F8FA'), ('app_button_color', '#FF2C4A63')");
    final v = PersonalizationViewModel(db)..loadFromDb();
    expect(v.appBackgroundFor(Brightness.dark), isNull);
    expect(v.appBackgroundFor(Brightness.light), const Color(0xFFF6F8FA));
    expect(v.appButtonFor(Brightness.light), const Color(0xFF2C4A63));
  });

  test('свои пресеты сохраняются и удаляются', () async {
    final (_, v) = await vm();
    const p = AppColorPreset(label: 'Мой', background: Color(0xFF101010), button: Color(0xFF3355AA), buttonText: Color(0xFFFFFFFF), custom: true);
    v.addCustomPreset(p);
    expect(v.customPresets.single.label, 'Мой');
    expect(v.customPresets.single.dark, isTrue);
    v.deleteCustomPreset(p);
    expect(v.customPresets, isEmpty);
  });
}
