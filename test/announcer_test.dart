import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/announcer.dart';

void main() {
  test('текст комментария: лидеры, выбывший, место спортсмена', () {
    final rows = [
      const AnnounceRow('Анна', 104.3, true),
      const AnnounceRow('Игорь', 103.9, true),
      const AnnounceRow('Олег', 103.0, true),
      const AnnounceRow('Вы', 101.5, true, isMe: true),
      const AnnounceRow('Мария', 90.0, false),
    ];
    final t = standingsSpeech(rows, eliminated: ['Мария']);
    expect(t, contains('Выбывает Мария.'));
    expect(t, contains('Лидирует Анна, 104,3.'));
    expect(t, contains('Второй Игорь, 103,9.'));
    expect(t, contains('Вы на 4-м месте, 101,5.'));
    expect(standingsSpeech(const []), '');
  });

  test('трекер: говорит один раз по началу паузы диктора, называет выбывших', () {
    final t = AnnounceTracker();
    List<AnnounceRow> rows(bool mariaActive) => [
          const AnnounceRow('Анна', 50, true),
          AnnounceRow('Мария', 40, mariaActive),
        ];
    expect(t.update(rows(true), announcing: false), isNull);
    final first = t.update(rows(false), announcing: true);
    expect(first, contains('Выбывает Мария.'));
    expect(t.update(rows(false), announcing: true), isNull); // пауза ещё идёт
    expect(t.update(rows(false), announcing: false), isNull);
  });
}
