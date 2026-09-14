import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../logic/chat_media_utils.dart';

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
      appBar: AppBar(title: Text(widget.isImage ? 'Фото' : 'Файл')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: widget.isImage
                  ? InteractiveViewer(child: Image.memory(widget.bytes, fit: BoxFit.contain))
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
                      decoration: const InputDecoration(hintText: 'Подпись (необязательно)', isDense: true),
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
