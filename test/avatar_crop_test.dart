import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shooting_app/logic/avatar_utils.dart';
import 'package:shooting_app/screens/avatar_crop_screen.dart';

void main() {
  test('кроп по координатам даёт квадрат 256 и не выходит за картинку', () {
    final src = img.Image(width: 400, height: 200);
    img.fill(src, color: img.ColorRgb8(10, 120, 200));
    final b64 = AvatarUtils.cropToBase64(src, 350, -50, 500); // вылезает за границы — подрезается
    final out = img.decodeImage(base64Decode(b64))!;
    expect(out.width, 256);
    expect(out.height, 256);
  });

  testWidgets('экран выбора области: «Готово» возвращает фото', (tester) async {
    final src = img.Image(width: 600, height: 300);
    img.fill(src, color: img.ColorRgb8(200, 50, 50));
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => result = await Navigator.of(ctx)
              .push<String>(MaterialPageRoute(builder: (_) => AvatarCropScreen(bytes: img.encodePng(src)))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(img.decodeImage(base64Decode(result!))!.width, 256);
  });
}
