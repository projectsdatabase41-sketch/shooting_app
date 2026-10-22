import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/athlete_insights.dart';
import 'package:shooting_app/services/coach_access_service.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  test('заметки о спортсмене сохраняются и читаются; отчёт за неделю собирается', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final m = AthleteMeta(group: 'Юниоры', archived: true, goal: '1 разряд', plan: [const PlanItem('2099-01-01', 'Зачёт')]);
    m.save(db, 'a1');
    final r = AthleteMeta.load(db, 'a1');
    expect(r.group, 'Юниоры');
    expect(r.archived, isTrue);
    expect(r.goal, '1 разряд');
    expect(r.plan.single.note, 'Зачёт');
    expect(AthleteMeta.load(db, 'нет').group, '');
    final text = weeklyReport('Иван', AthleteStats(status: ShareTokenStatus.valid, last: DateTime.now(), n7: 2, n30: 5, avgShot: 10.2, bestShot: 10.9, bestTotal: 105.1, recentCount: 3), r);
    expect(text, contains('Иван'));
    expect(text, contains('10.20'));
    expect(text, contains('Зачёт'));
  });
}
