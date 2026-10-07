import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/ai_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';

Future<AiSettings> _fresh() async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  return AiSettings(db);
}

void main() {
  test('режим по умолчанию — Normal', () async {
    final s = await _fresh();
    expect(s.chatMode, 'normal');
    expect(s.modelPriority, 'quality');
    expect(s.thinkingMode, isFalse);
  });

  test('выбор режима сохраняется; Fast переворачивает цепочку моделей, Think включает размышление', () async {
    final s = await _fresh();
    s.chatMode = 'fast';
    expect(s.chatMode, 'fast');
    expect(s.modelPriority, 'speed');
    s.chatMode = 'think';
    expect(s.thinkingMode, isTrue);
    expect(s.modelPriority, 'quality');
    s.chatMode = 'мусор';
    expect(s.chatMode, 'normal');
  });

  test('старые настройки переезжают: мышление → Think, скорость → Fast', () async {
    final a = await _fresh();
    a.db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('ai_thinking_mode', '1')");
    expect(a.chatMode, 'think');
    final b = await _fresh();
    b.db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('ai_model_priority', 'speed')");
    expect(b.chatMode, 'fast');
  });
}
