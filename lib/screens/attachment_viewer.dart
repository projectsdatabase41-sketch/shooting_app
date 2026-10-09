import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/chat_media_utils.dart';
import '../widgets/file_chip.dart';
import '../widgets/glass_pill.dart';
import 'pdf_viewer_screen.dart';
import 'photo_viewer_screen.dart';

/// Открытие вложения чата внутри приложения: картинки — полноэкранный
/// просмотр, PDF — читалка, текстовые файлы — текст. Остальное показать
/// внутри нечем: карточка с кнопкой «Открыть в другом приложении».
class AttachmentViewer {
  AttachmentViewer._();

  static const _textExt = {
    'txt', 'md', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'sql', 'tsv', 'cfg', 'conf', 'gpx',
  };
  static const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Какой просмотрщик подойдёт: image | pdf | text | other.
  static String kindOf(String name, String? mime) {
    final e = _ext(name);
    if (_imageExt.contains(e) || (mime?.startsWith('image/') ?? false)) return 'image';
    if (e == 'pdf' || mime == 'application/pdf') return 'pdf';
    if (_textExt.contains(e) || (mime?.startsWith('text/') ?? false)) return 'text';
    return 'other';
  }

  static Future<void> open(BuildContext context,
      {required String name, required Uint8List bytes, String? mime}) async {
    switch (kindOf(name, mime)) {
      case 'image':
        await PhotoViewerScreen.open(context, MemoryImage(bytes));
      case 'pdf':
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => PdfViewerScreen(bytes: bytes, fileName: name)));
      case 'text':
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => _TextViewerScreen(name: name, bytes: bytes, mime: mime)));
      default:
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => _OtherViewerScreen(name: name, bytes: bytes, mime: mime)));
    }
  }
}

class _TextViewerScreen extends StatelessWidget {
  final String name;
  final Uint8List bytes;
  final String? mime;
  const _TextViewerScreen({required this.name, required this.bytes, this.mime});

  @override
  Widget build(BuildContext context) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          GlassCircleButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: tr('Поделиться'),
            onTap: () => ChatMediaUtils.shareAttachment(bytes, name, mime),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35)),
      ),
    );
  }
}

class _OtherViewerScreen extends StatelessWidget {
  final String name;
  final Uint8List bytes;
  final String? mime;
  const _OtherViewerScreen({required this.name, required this.bytes, this.mime});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ext = FileChip.extOf(name);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(name, overflow: TextOverflow.ellipsis)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(ext,
                    style: TextStyle(
                        color: FileChip.accentFor(ext, cs.onSurface),
                        fontSize: 30,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 16),
              Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(ChatMediaUtils.formatSize(bytes.length), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              Text(
                tr('Этот тип файла нельзя показать внутри приложения.'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: Text(tr('Открыть в другом приложении')),
                onPressed: () => ChatMediaUtils.shareAttachment(bytes, name, mime),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
