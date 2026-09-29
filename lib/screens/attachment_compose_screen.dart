import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../logic/chat_media_utils.dart';
import '../widgets/glass_pill.dart';
import '../i18n/i18n.dart';

/// Предпросмотр фото/файла перед отправкой — подпись пишется здесь, а не
/// добавляется отдельным сообщением потом (решение пользователя: фото
/// не должно уходить в чат сразу по выбору файла). Возвращает подпись
/// (может быть пустой) через `Navigator.pop`, либо `null`, если открепили.
class AttachmentComposeScreen extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final bool isImage;

  const AttachmentComposeScreen({super.key, required this.bytes, required this.fileName, required this.isImage});

  @override
  State<AttachmentComposeScreen> createState() => _AttachmentComposeScreenState();
}

class _AttachmentComposeScreenState extends State<AttachmentComposeScreen> {
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(widget.isImage ? tr('Фото') : tr('Файл'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: widget.isImage
                  // maxScale/SizedBox.expand — как в PhotoViewerScreen (просмотр
                  // уже отправленного фото): без SizedBox.expand ребёнок
                  // InteractiveViewer сжимается под размер картинки, а не
                  // вьюпорта, и жесту почти некуда «увеличивать» — зум
                  // казался нерабочим именно для ещё не отправленного фото.
                  ? InteractiveViewer(
                      maxScale: 6,
                      clipBehavior: Clip.none,
                      child: SizedBox.expand(child: Image.memory(widget.bytes, fit: BoxFit.contain)),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.insert_drive_file_outlined, size: 64),
                          const SizedBox(height: 12),
                          Text(widget.fileName, textAlign: TextAlign.center),
                          Text(ChatMediaUtils.formatSize(widget.bytes.length)),
                        ],
                      ),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      autofocus: widget.isImage,
                      decoration: InputDecoration(hintText: tr('Подпись (необязательно)'), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => Navigator.of(context).pop(_caption.text.trim()),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
