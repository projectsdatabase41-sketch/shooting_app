import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/app_update_service.dart';

void main() {
  const oldSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const newSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  Map<String, dynamic> release({String? body, List<Map<String, dynamic>>? assets}) => {
        'body': body ?? 'Автособрано из $newSha',
        'assets': assets ?? [
          {'name': 'app-release.apk', 'browser_download_url': 'https://example.com/app-release.apk'},
        ],
      };

  test('другой SHA и есть .apk среди assets — апдейт есть', () {
    final info = AppUpdateService.parseRelease(release(), oldSha);
    expect(info, isNotNull);
    expect(info!.sha, newSha);
    expect(info.downloadUrl, 'https://example.com/app-release.apk');
  });

  test('тот же SHA — апдейта нет', () {
    expect(AppUpdateService.parseRelease(release(body: 'Автособрано из $oldSha'), oldSha), isNull);
  });

  test('в теле релиза нет SHA (сломался формат) — молча null, не бросает', () {
    expect(AppUpdateService.parseRelease(release(body: 'что-то не то'), oldSha), isNull);
  });

  test('нет .apk среди assets — null', () {
    final info = AppUpdateService.parseRelease(
      release(assets: [
        {'name': 'notes.txt', 'browser_download_url': 'https://example.com/notes.txt'},
      ]),
      oldSha,
    );
    expect(info, isNull);
  });

  test('assets пустой список или отсутствует — null, не бросает', () {
    expect(AppUpdateService.parseRelease(release(assets: []), oldSha), isNull);
    expect(AppUpdateService.parseRelease({'body': 'Автособрано из $newSha'}, oldSha), isNull);
  });
}
