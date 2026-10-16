import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/voice_recorder.dart';

void main() {
  test('волна: уровни сжимаются в 48 hex-символов, тишина = 0, пик = f', () {
    final levels = [for (var i = 0; i < 200; i++) i < 100 ? 0.0 : 1.0];
    final w = VoiceRecorder.encodeWave(levels);
    expect(w.length, 48);
    expect(w.substring(0, 20), '0' * 20);
    expect(w.substring(30), 'f' * 18);
    expect(VoiceRecorder.encodeWave(const []), '');
    expect(RegExp(r'^[0-9a-f]{48}$').hasMatch(w), isTrue);
  });
}
