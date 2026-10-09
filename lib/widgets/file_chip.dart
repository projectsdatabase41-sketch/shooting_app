import 'package:flutter/material.dart';

/// Ярлык файла в чате: квадратная кнопка с расширением файла вместо
/// картинки и названием снизу. Нажатие открывает файл внутри приложения;
/// большой файл с сервера при первом нажатии скачивается незаметно.
class FileChip extends StatelessWidget {
  final String name;
  final int? size;
  final Color fg;

  /// Файл ещё лежит на сервере (скачается при нажатии) — в углу облачко.
  final bool remote;

  /// Идёт скачивание — в углу крутится индикатор.
  final bool busy;

  /// Кнопка «Загрузить» (сохранить в папку Nexus); `null` — не показывать.
  /// Показывается один раз: после сохранения родитель её убирает.
  final VoidCallback? onSave;
  final VoidCallback? onTap;

  const FileChip({
    super.key,
    required this.name,
    required this.fg,
    this.size,
    this.remote = false,
    this.busy = false,
    this.onSave,
    this.onTap,
  });

  static const double width = 112;

  /// Расширение для надписи на кнопке (до 4 символов, заглавными).
  static String extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'FILE';
    final e = name.substring(dot + 1).toUpperCase();
    return e.length > 4 ? e.substring(0, 4) : e;
  }

  /// Цвет надписи по семейству файла.
  static Color accentFor(String ext, Color fallback) => switch (ext) {
        'PDF' => const Color(0xFFE53935),
        'DOC' || 'DOCX' || 'RTF' || 'ODT' => const Color(0xFF4C7DF5),
        'XLS' || 'XLSX' || 'CSV' || 'ODS' => const Color(0xFF2E9E5B),
        'PPT' || 'PPTX' || 'ODP' => const Color(0xFFE8742A),
        'ZIP' || 'RAR' || '7Z' || 'TAR' || 'GZ' => const Color(0xFFD9A441),
        _ => fallback,
      };

  String _sizeText() {
    final b = size;
    if (b == null) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final ext = extOf(name);
    final accent = accentFor(ext, fg);
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Container(
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: fg.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      ext,
                      style: TextStyle(
                        color: accent,
                        fontSize: ext.length > 3 ? 22 : 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  if (busy)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                      ),
                    )
                  else if (remote)
                    Positioned(
                      top: 5,
                      right: 5,
                      child: Icon(Icons.cloud_download_outlined, size: 18, color: fg.withValues(alpha: 0.8)),
                    )
                  else if (onSave != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: InkResponse(
                        onTap: onSave,
                        radius: 18,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.download_outlined, size: 18, color: fg.withValues(alpha: 0.85)),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: fg, fontSize: 12, height: 1.15),
              ),
              if (_sizeText().isNotEmpty)
                Text(
                  _sizeText(),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
