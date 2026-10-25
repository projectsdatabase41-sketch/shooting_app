import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shooting_app/logic/chat_media_utils.dart';

void main() {
  test('сжатие фото: обычное — до 1600 px, HD — до 3200 px и тяжелее', () {
    final src = img.Image(width: 4000, height: 3000);
    for (var y = 0; y < src.height; y += 7) {
      for (var x = 0; x < src.width; x += 5) {
        src.setPixelRgb(x, y, (x * 3) % 256, (y * 5) % 256, (x + y) % 256);
      }
    }
    final bytes = img.encodePng(src);
    final normal = img.decodeJpg(ChatMediaUtils.compressImage(bytes)!)!;
    final hd = img.decodeJpg(ChatMediaUtils.compressImage(bytes, hd: true)!)!;
    expect(normal.width, 1600);
    expect(hd.width, 3200);
    expect(ChatMediaUtils.compressImage(bytes, hd: true)!.length, greaterThan(ChatMediaUtils.compressImage(bytes)!.length));
  });
}
