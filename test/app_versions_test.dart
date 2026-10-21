import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/app_update_service.dart';

void main() {
  const cur = 'cccccccccccccccccccccccccccccccccccccccc';

  test('version.json с номером версии', () {
    final i = AppUpdateService.parseVersionJson({'sha': 'dddddddddddddddd', 'built': '2026-10-21T10:00:00Z', 'version': '0.12'}, cur, 'x/y');
    expect(i!.version, '0.12');
  });
}
