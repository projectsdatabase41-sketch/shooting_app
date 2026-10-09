import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/attachment_viewer.dart';
import 'package:shooting_app/widgets/file_chip.dart';

void main() {
  test('расширение для кнопки и вид просмотрщика', () {
    expect(FileChip.extOf('Правила.final.pdf'), 'PDF');
    expect(FileChip.extOf('архив.tar.gz'), 'GZ');
    expect(FileChip.extOf('noext'), 'FILE');
    expect(FileChip.extOf('файл.markdown'), 'MARK');
    expect(AttachmentViewer.kindOf('a.PDF', null), 'pdf');
    expect(AttachmentViewer.kindOf('a.jpg', null), 'image');
    expect(AttachmentViewer.kindOf('заметки.txt', null), 'text');
    expect(AttachmentViewer.kindOf('отчёт.docx', null), 'other');
    expect(AttachmentViewer.kindOf('x', 'image/png'), 'image');
  });

  testWidgets('ярлык: расширение на кнопке, название снизу; кнопка «Загрузить» нажимается отдельно', (tester) async {
    var opened = 0, saved = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: FileChip(
              name: 'Правила стрельбы.pdf',
              size: 2048,
              fg: Colors.white,
              onTap: () => opened++,
              onSave: () => saved++),
        ),
      ),
    ));
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('Правила стрельбы.pdf'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
    await tester.tap(find.text('PDF'));
    expect(opened, 1);
    await tester.tap(find.byIcon(Icons.download_outlined));
    expect(saved, 1);
    expect(opened, 1);
  });

  testWidgets('без onSave кнопки нет; файл на сервере — облачко, при скачивании — индикатор', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: FileChip(name: 'a.zip', fg: Colors.white, remote: true))),
    ));
    expect(find.byIcon(Icons.download_outlined), findsNothing);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: FileChip(name: 'a.zip', fg: Colors.white, remote: true, busy: true))),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsNothing);
  });
}
