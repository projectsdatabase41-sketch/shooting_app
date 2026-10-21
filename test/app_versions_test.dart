import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/app_update_service.dart';

void main() {
  const cur = 'cccccccccccccccccccccccccccccccccccccccc';
  final rows = [
    {'version': '0.12', 'sha': 'dddddddddddddddddddddddddddddddddddddddd', 'built': '2026-10-21T10:00:00Z', 'url': 'https://github.com/x/y/releases/download/v0.12/app-release.apk'},
    {'version': '0.11', 'sha': cur, 'built': '2026-10-20T10:00:00Z', 'url': 'https://github.com/x/y/releases/download/v0.11/app-release.apk'},
    {'version': '0.10', 'sha': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', 'built': '2026-10-19T10:00:00Z', 'url': 'https://github.com/x/y/releases/download/v0.10/app-release.apk'},
    {'version': 'bad', 'sha': 'x', 'url': 'http://evil'},
  ];

  test('список отката: текущая и негодные записи отбрасываются, порядок сохраняется', () {
    final list = AppUpdateService.parseVersions(rows, cur);
    expect(list.map((e) => e.version), ['0.12', '0.10']);
    expect(list.first.downloadUrl, startsWith('https://github.com/'));
  });

  test('не список — пусто, не бросает', () {
    expect(AppUpdateService.parseVersions({'a': 1}, cur), isEmpty);
    expect(AppUpdateService.parseVersions(null, cur), isEmpty);
  });

  test('version.json с номером версии', () {
    final i = AppUpdateService.parseVersionJson({'sha': 'dddddddddddddddd', 'built': '2026-10-21T10:00:00Z', 'version': '0.12'}, cur, 'x/y');
    expect(i!.version, '0.12');
  });
}
