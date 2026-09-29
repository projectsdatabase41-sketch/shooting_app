import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../widgets/glass_pill.dart';

/// Просмотр PDF прямо в приложении — вместо ухода во внешнее приложение
/// (решение пользователя: "удобный просмотр файлов внутри приложения").
/// Каждая страница листается и зумится жестами — то же самое ощущение,
/// что и у просмотра фото.
class PdfViewerScreen extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  const PdfViewerScreen({super.key, required this.bytes, required this.fileName});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final _controller = PdfViewerController();
  int? _page;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(widget.fileName,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          if (_page != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text('$_page / ${_controller.isReady ? _controller.pageCount : '…'}',
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
        ],
      ),
      body: PdfViewer.data(
        widget.bytes,
        sourceName: widget.fileName,
        controller: _controller,
        params: PdfViewerParams(onPageChanged: (page) => setState(() => _page = page)),
      ),
    );
  }
}
