import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/share_grant.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  test('политика токена и список таблиц переживают локальное зеркало', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db);
    store.replaceShareGrants([
      ShareGrant(id: 'g1', tokenHash: 'h', athleteLabel: 'Тренер', createdAt: DateTime(2026, 1, 1), policy: 'extended', tables: ['notes', 'diary']),
      ShareGrant(id: 'g2', tokenHash: 'h2', athleteLabel: 'Другой', createdAt: DateTime(2026, 1, 2)),
    ]);
    final g1 = store.shareGrants.firstWhere((g) => g.id == 'g1');
    final g2 = store.shareGrants.firstWhere((g) => g.id == 'g2');
    expect(g1.isExtended, isTrue);
    expect(g1.tables, ['notes', 'diary']);
    expect(g2.isExtended, isFalse);
    expect(g2.tables, isEmpty);
  });
}
