import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/main.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/user_profile.dart';

void main() {
  testWidgets('анкета: при первом открытии показывается обязательная анкета; без года «Продолжить» неактивна', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    await tester.pumpWidget(ShootingApp(db: db));
    await tester.pump();
    expect(find.text('Профиль спортсмена'), findsOneWidget);
    FilledButton button() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Продолжить'));
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'Иван');
    await tester.enterText(find.byType(TextField).at(1), 'Петров');
    await tester.tap(find.text('Пистолет'));
    await tester.tap(find.text('Мужской'));
    await tester.pump();
    expect(button().onPressed, isNull); // нет года
    await tester.enterText(find.byType(TextField).at(2), '2030'); // слишком молодой
    await tester.pump();
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField).at(2), '2000');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(UserProfile.needsOnboarding(db), isFalse);
    expect(UserProfile.disciplinesOf(db), ['pistol']);
    expect(UserProfile.firstNameOf(db), 'Иван');
    expect(UserProfile.lastNameOf(db), 'Петров');
    expect(UserProfile.genderOf(db), 'm');
    expect(UserProfile.birthYearOf(db), 2000);
    expect(find.text('Профиль спортсмена'), findsNothing); // открыт главный экран
    expect(find.text('Синхронизация с облаком'), findsOneWidget); // предложение после анкеты
  });
}
