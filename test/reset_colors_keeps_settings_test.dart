import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/personalization_view_model.dart';

void main() {
  test('«Сбросить все цвета» не трогает прозрачность плиток, модули и прочие настройки', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    void put(String k, String v) => db.db.execute('INSERT OR REPLACE INTO color_prefs (key, hex) VALUES (?, ?)', [k, v]);
    for (final e in {
      'tile_glass': '1',
      'tile_alpha': '0.6',
      'home_tile_max_px': '360',
      'module_messenger': '1',
      'modules_initialized': '1',
      'wallpaper_mask': '0.5',
      'app_locale': 'en',
      'target_paper': '#ffffff',
      'shot_number_text_auto': '0',
    }.entries) {
      put(e.key, e.value);
    }
    final vm = PersonalizationViewModel(db)..loadFromDb();
    vm.resetAll();
    String? get(String k) {
      final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
      return r.isEmpty ? null : '${r.first['hex']}';
    }

    expect(get('tile_glass'), '1');
    expect(get('tile_alpha'), '0.6');
    expect(get('home_tile_max_px'), '360');
    expect(get('module_messenger'), '1');
    expect(get('wallpaper_mask'), '0.5');
    expect(get('app_locale'), 'en');
    expect(get('target_paper'), isNull);
    expect(get('shot_number_text_auto'), isNull);
  });
}
