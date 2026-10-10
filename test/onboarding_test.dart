import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/user_profile.dart';

void main() {
  testWidgets('анкета: при первом открытии показывается обязательная анкета; без года «Продолжить» неактивна', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    await tester.pumpWidget(ShootingApp(db: db));
    await tester.pump();
    expect(find.text('Профиль спортсмена'), findsOneWidget);
    FilledButton button() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Продолжить'));
    expect(button().onPressed, isNull);

    await tester.tap(find.text('Пистолет'));
    await tester.tap(find.text('Мужской'));
    await tester.pump();
    expect(button().onPressed, isNull); // нет года
    await tester.enterText(find.byType(TextField).first, '2030'); // слишком молодой
    await tester.pump();
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, '2000');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(UserProfile.needsOnboarding(db), isFalse);
    expect(UserProfile.disciplinesOf(db), ['pistol']);
    expect(UserProfile.genderOf(db), 'm');
    expect(UserProfile.birthYearOf(db), 2000);
    expect(find.text('Профиль спортсмена'), findsNothing); // открыт главный экран
    expect(find.text('Синхронизация с облаком'), findsOneWidget); // предложение после анкеты
  });
}
