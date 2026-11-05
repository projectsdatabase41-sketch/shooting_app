import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/attachment_viewer.dart';
import 'package:shooting_app/widgets/audio_file_bubble.dart';
import 'package:shooting_app/widgets/voice_bubble.dart' show MediaSource;

/// Отзыв от 02.11.2026: присланный в чат mp3 открывался как «этот тип файла
/// нельзя показать внутри приложения». Здесь проверяется, что аудио теперь
/// распознаётся и показывается плеером, а не заглушкой «неизвестный файл».
void main() {
  group('AttachmentViewer: определение аудио', () {
    test('mp3 из отзыва — это аудио', () {
      expect(AttachmentViewer.kindOf('openrouter-audio-output.mp3', null),
          'audio');
      expect(AttachmentViewer.isAudio('openrouter-audio-output.mp3', null),
          isTrue);
    });

    test('остальные аудиоформаты', () {
      for (final name in [
        'rec.wav',
        'rec.m4a',
        'rec.aac',
        'rec.ogg',
        'rec.oga',
        'rec.opus',
        'rec.flac',
        'rec.amr',
        'REC.MP3', // регистр не важен
      ]) {
        expect(AttachmentViewer.kindOf(name, null), 'audio', reason: name);
      }
    });

    test('MIME важнее расширения', () {
      expect(AttachmentViewer.kindOf('voice.bin', 'audio/mpeg'), 'audio');
      expect(AttachmentViewer.isAudio('voice.bin', 'audio/ogg'), isTrue);
    });

    test('не аудио не перехватывается', () {
      expect(AttachmentViewer.kindOf('photo.jpg', null), 'image');
      expect(AttachmentViewer.kindOf('doc.pdf', null), 'pdf');
      expect(AttachmentViewer.kindOf('notes.txt', null), 'text');
      expect(AttachmentViewer.kindOf('setup.exe', null), 'other');
      expect(AttachmentViewer.kindOf('archive.zip', null), 'other');
    });
  });

  group('AudioFileBubble: мини-плеер в пузыре', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AudioFileBubble(
            name: 'openrouter-audio-output.mp3',
            size: 181248,
            fg: Colors.black87,
            mine: false,
            load: () async =>
                MediaSource(bytes: Uint8List(16), mime: 'audio/mpeg'),
            onOpenFull: () {},
            onSave: () {},
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('показывает название, время и кнопки управления',
        (tester) async {
      await pump(tester);
      expect(find.text('openrouter-audio-output.mp3'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      // «Скачать» — в углу, отдельной кнопкой (просьба из отзыва).
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('уже скачанное не предлагает скачать снова', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AudioFileBubble(
            name: 'rec.wav',
            size: 1000,
            fg: Colors.black87,
            mine: true,
            load: () async => null,
            onOpenFull: () {},
            onSave: () {},
            saved: true,
          ),
        ),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });
  });
}
