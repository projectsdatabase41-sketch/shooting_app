import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/tile_backdrop.dart';

void main() {
  test('у каждой плитки свои обои, остальные — общие; все картинки на месте', () {
    expect(TileBackdropPage.kindFor('assistant'), 'ai');
    expect(TileBackdropPage.kindFor('notes'), 'notes');
    expect(TileBackdropPage.kindFor('drive'), 'drive');
    expect(TileBackdropPage.kindFor('service_x'), 'settings');
    expect(TileBackdropPage.kindFor(null), 'settings');
    for (final k in ['exercises', 'statistics', 'tasks', 'athletes', 'ai', 'notes', 'finals', 'messenger', 'drive', 'settings']) {
      final kind = TileBackdropPage.kindFor(k == 'ai' ? 'assistant' : k);
      for (final t in ['dark', 'light']) {
        expect(File('assets/wall/${kind}_$t.jpg').existsSync(), isTrue, reason: '$kind $t');
        expect(File('assets/wall/${kind}_${t}_b.jpg').existsSync(), isTrue, reason: '$kind $t blur');
      }
    }
  });
}
