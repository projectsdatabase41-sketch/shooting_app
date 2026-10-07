import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/photo_viewer_screen.dart';

Future<Uint8List> _wideImage() async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 40, 10), Paint()..color = Colors.red);
  final img = await rec.endRecording().toImage(40, 10);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  testWidgets('тап по фону вне картинки закрывает просмотр, тап по картинке — нет', (tester) async {
    final bytes = await tester.runAsync(_wideImage);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => PhotoViewerScreen.open(c, MemoryImage(bytes!)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height / 2)); // по картинке
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsOneWidget);

    await tester.tapAt(Offset(size.width / 2, size.height * 0.9)); // фон ниже картинки
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
  });
}
