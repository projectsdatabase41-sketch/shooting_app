import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/chat_auth_service.dart';
import '../services/pdf_tools_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';

/// PDF-инструменты: объединить, разделить, сжать, конвертировать и прочее.
/// Обработка идёт на нашем сервере (iLoveAPI), ключ в приложении не хранится.
class PdfToolsScreen extends StatefulWidget {
  const PdfToolsScreen({super.key});

  @override
  State<PdfToolsScreen> createState() => PdfToolsScreenState();
}

class PdfToolsScreenState extends State<PdfToolsScreen> {
  late final PdfToolsService _service;

  String _tool = 'merge';
  List<({String name, Uint8List bytes})> _files = const [];
  bool _busy = false;
  String? _message;
  Uint8List? _result;

  // Параметры задач (показываются только у подходящих инструментов).
  String _compress = 'recommended';
  String _splitMode = 'ranges';
  final _ranges = TextEditingController(text: '1-3');
  final _fixedRange = TextEditingController(text: '1');
  final _pages = TextEditingController();
  final _wmText = TextEditingController(text: 'Nexus');
  String _wmVertical = 'center';
  String _wmHorizontal = 'center';
  final _pnText = TextEditingController(text: '{n}');
  String _pnPosition = 'bottom-center';
  int _rotate = 90;
  final _password = TextEditingController();
  String _ocrLang = 'rus+eng';
  final _dpi = TextEditingController(text: '150');
  String _conformance = 'pdfa2b';

  @override
  void initState() {
    super.initState();
    _service = PdfToolsService(ChatAuthService(context.read<AppDataStore>().db));
  }

  @override
  void dispose() {
    for (final c in [_ranges, _fixedRange, _pages, _wmText, _pnText, _password, _dpi]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _single => PdfToolsService.singleFileTools.contains(_tool);

  /// Файлы всё ещё PDF? Тогда бессмысленные конвертеры (Office/HTML/картинки)
  /// в списке не показываем — меньше путаницы (отзыв 19.11).
  bool get _onlyPdf => _files.isNotEmpty && _files.every((f) => f.name.toLowerCase().endsWith('.pdf'));

  Set<String> get _allowedTools {
    if (_files.isEmpty) return PdfToolsService.tools.keys.toSet();
    if (_onlyPdf) {
      return PdfToolsService.tools.keys
          .where((k) => !const {'officepdf', 'htmlpdf', 'imagepdf'}.contains(k))
          .toSet();
    }
    // Не PDF: имеет смысл только конвертация в PDF.
    return const {'officepdf', 'imagepdf', 'htmlpdf'};
  }

  /// Параметры для сервера: только те, что нужны выбранному инструменту.
  Map<String, dynamic>? _options() {
    switch (_tool) {
      case 'compress':
        return {'compression_level': _compress};
      case 'split':
        return {
          'split_mode': _splitMode,
          if (_splitMode == 'ranges') 'ranges': _ranges.text.trim(),
          if (_splitMode == 'fixed_range') 'fixed_range': int.tryParse(_fixedRange.text.trim()) ?? 1,
          if (_splitMode == 'remove_pages') 'remove_pages': _pages.text.trim(),
        };
      case 'pagenumber':
        return {
          'text': _pnText.text.trim().isEmpty ? '{n}' : _pnText.text.trim(),
          'position': _pnPosition,
          if (_pages.text.trim().isNotEmpty) 'pages': _pages.text.trim(),
        };
      case 'watermark':
        return {
          'mode': 'text',
          'text': _wmText.text.trim().isEmpty ? 'Nexus' : _wmText.text.trim(),
          'vertical_position': _wmVertical,
          'horizontal_position': _wmHorizontal,
          if (_pages.text.trim().isNotEmpty) 'pages': _pages.text.trim(),
        };
      case 'rotate':
        return {'rotate': _rotate};
      case 'protect':
      case 'unlock':
        return {if (_password.text.isNotEmpty) 'password': _password.text};
      case 'ocr':
        return {'ocr_language': _ocrLang};
      case 'pdfjpg':
        return {'pdfjpg_mode': 'pages', 'dpi': int.tryParse(_dpi.text.trim()) ?? 150};
      case 'pdfa':
        return {'conformance': _conformance};
      default:
        return null;
    }
  }

  Future<void> _pick() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: !_single,
      withData: true,
    );
    if (picked == null) return;
    final files = <({String name, Uint8List bytes})>[];
    for (final f in picked.files) {
      final bytes = f.bytes;
      if (bytes != null) files.add((name: f.name, bytes: bytes));
    }
    if (files.isEmpty) {
      // Молчаливый выход выглядел как «файл не выбрался» (отзыв 20.11,
      // 17:27). Пикер иногда отдаёт запись без байтов (например, ссылка на
      // облачный файл) — говорим об этом прямо.
      setState(() => _message = tr('Не удалось прочитать выбранный файл. Попробуйте другой.'));
      return;
    }
    setState(() {
      _files = _single ? files.take(1).toList() : files;
      _result = null;
      _message = null;
      if (!_allowedTools.contains(_tool)) {
        _tool = _onlyPdf ? 'merge' : 'officepdf';
      }
    });
  }

  Future<void> _run() async {
    if (_busy) return;
    if (_files.isEmpty) {
      // Раньше кнопка просто не нажималась — пользователь решил, что она
      // сломана (отзыв 20.11, 17:27). Теперь она нажимается и объясняет.
      setState(() => _message = tr('Сначала выберите файл'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
    });
    try {
      final uploaded = <({String id, String name})>[];
      for (final f in _files) {
        final up = await _service.upload(f.bytes, f.name);
        if (up == null) {
          setState(() => _message = tr('Не удалось загрузить файл: {n}', {'n': f.name}));
          return;
        }
        uploaded.add(up);
      }
      final id = await _service.run(_tool, uploaded, options: _options());
      if (id == null) {
        final hint = PdfToolsService.lastError;
        setState(() {
          _message = PdfToolsService.notConfigured
              ? tr('Модуль PDF ещё не настроен: нужен ключ iLoveAPI на сервере.')
              : tr('Не получилось обработать файл: {e}', {'e': hint ?? ''});
        });
        return;
      }
      final out = await _service.download(id);
      if (!mounted) return;
      setState(() {
        _result = out;
        _message = out == null ? tr('Результат не скачался') : tr('Готово');
      });
    } catch (e) {
      // Без catch исключение уходило в необработанную ошибку: спиннер
      // гас, а на экране не появлялось ничего (отзыв «нажал — ничего»).
      if (mounted) setState(() => _message = tr('Ошибка: {e}', {'e': friendlyError(e)}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final data = _result;
    if (data == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final name = '${_tool}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: tr('PDF-инструменты'),
      ));
    } catch (_) {}
  }

  /// Параметры выбранного инструмента.
  List<Widget> _optionsUi(ThemeData theme) {
    final label = theme.textTheme.labelLarge;
    Widget field(TextEditingController c, String title, {String? hint}) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            controller: c,
            decoration: InputDecoration(labelText: tr(title), helperText: hint),
          ),
        );

    switch (_tool) {
      case 'compress':
        return [
          const SizedBox(height: 12),
          Text(tr('Сжатие'), style: label),
          DropdownButtonFormField<String>(
            initialValue: _compress,
            items: [
              DropdownMenuItem(value: 'recommended', child: Text(tr('Рекомендованное'))),
              DropdownMenuItem(value: 'extreme', child: Text(tr('Максимальное (сильнее жмёт)'))),
              DropdownMenuItem(value: 'low', child: Text(tr('Слабое (лучше качество)'))),
            ],
            onChanged: (v) => setState(() => _compress = v ?? _compress),
          ),
        ];
      case 'split':
        return [
          const SizedBox(height: 12),
          Text(tr('Режим разделения'), style: label),
          DropdownButtonFormField<String>(
            initialValue: _splitMode,
            items: [
              DropdownMenuItem(value: 'ranges', child: Text(tr('По диапазонам страниц'))),
              DropdownMenuItem(value: 'fixed_range', child: Text(tr('Каждые N страниц'))),
              DropdownMenuItem(value: 'remove_pages', child: Text(tr('Удалить страницы'))),
            ],
            onChanged: (v) => setState(() => _splitMode = v ?? _splitMode),
          ),
          if (_splitMode == 'ranges') field(_ranges, 'Диапазоны', hint: '1-3,5,8-10'),
          if (_splitMode == 'fixed_range') field(_fixedRange, 'Страниц в части', hint: '1'),
          if (_splitMode == 'remove_pages') field(_pages, 'Удалить страницы', hint: '2,4,7-9'),
        ];
      case 'pagenumber':
        return [
          const SizedBox(height: 12),
          Text(tr('Номера страниц'), style: label),
          field(_pnText, 'Текст', hint: '{n} — номер, {p} — всего'),
          DropdownButtonFormField<String>(
            initialValue: _pnPosition,
            items: [
              DropdownMenuItem(value: 'bottom-left', child: Text(tr('Снизу слева'))),
              DropdownMenuItem(value: 'bottom-center', child: Text(tr('Снизу по центру'))),
              DropdownMenuItem(value: 'bottom-right', child: Text(tr('Снизу справа'))),
              DropdownMenuItem(value: 'top-left', child: Text(tr('Сверху слева'))),
              DropdownMenuItem(value: 'top-center', child: Text(tr('Сверху по центру'))),
              DropdownMenuItem(value: 'top-right', child: Text(tr('Сверху справа'))),
            ],
            onChanged: (v) => setState(() => _pnPosition = v ?? _pnPosition),
          ),
        ];
      case 'watermark':
        return [
          const SizedBox(height: 12),
          Text(tr('Водяной знак'), style: label),
          field(_wmText, 'Надпись'),
          DropdownButtonFormField<String>(
            initialValue: _wmVertical,
            items: [
              DropdownMenuItem(value: 'top', child: Text(tr('Сверху'))),
              DropdownMenuItem(value: 'center', child: Text(tr('По центру'))),
              DropdownMenuItem(value: 'bottom', child: Text(tr('Снизу'))),
            ],
            onChanged: (v) => setState(() => _wmVertical = v ?? _wmVertical),
          ),
          DropdownButtonFormField<String>(
            initialValue: _wmHorizontal,
            items: [
              DropdownMenuItem(value: 'left', child: Text(tr('Слева'))),
              DropdownMenuItem(value: 'center', child: Text(tr('По центру'))),
              DropdownMenuItem(value: 'right', child: Text(tr('Справа'))),
            ],
            onChanged: (v) => setState(() => _wmHorizontal = v ?? _wmHorizontal),
          ),
        ];
      case 'rotate':
        return [
          const SizedBox(height: 12),
          Text(tr('Поворот'), style: label),
          DropdownButtonFormField<int>(
            initialValue: _rotate,
            items: [
              DropdownMenuItem(value: 90, child: Text(tr('90° по часовой'))),
              DropdownMenuItem(value: 180, child: Text(tr('180°'))),
              DropdownMenuItem(value: 270, child: Text(tr('270°'))),
            ],
            onChanged: (v) => setState(() => _rotate = v ?? _rotate),
          ),
        ];
      case 'protect':
      case 'unlock':
        return [field(_password, _tool == 'protect' ? 'Пароль для PDF' : 'Пароль файла')];
      case 'ocr':
        return [
          const SizedBox(height: 12),
          Text(tr('Язык распознавания'), style: label),
          DropdownButtonFormField<String>(
            initialValue: _ocrLang,
            items: [
              DropdownMenuItem(value: 'rus+eng', child: Text(tr('Русский + английский'))),
              DropdownMenuItem(value: 'rus', child: Text(tr('Русский'))),
              DropdownMenuItem(value: 'eng', child: Text(tr('Английский'))),
            ],
            onChanged: (v) => setState(() => _ocrLang = v ?? _ocrLang),
          ),
        ];
      case 'pdfjpg':
        return [
          const SizedBox(height: 12),
          field(_dpi, 'Качество (DPI)', hint: '150 — обычно хватает'),
        ];
      case 'pdfa':
        return [
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _conformance,
            items: [
              DropdownMenuItem(value: 'pdfa1b', child: Text('PDF/A-1b')),
              DropdownMenuItem(value: 'pdfa2b', child: Text('PDF/A-2b')),
              DropdownMenuItem(value: 'pdfa3b', child: Text('PDF/A-3b')),
            ],
            onChanged: (v) => setState(() => _conformance = v ?? _conformance),
          ),
        ];
      default:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('PDF-инструменты'))),
      body: AppBackdrop(
        kind: 'settings',
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 32),
          children: [
            Text(
                tr('Файлы обрабатываются на нашем сервере: объединить, разделить, сжать, перевести в PDF и обратно, поставить номера страниц или водяной знак. Файлы в приложении не сохраняются.'),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // Ключ от выбранного инструмента: без него Dropdown держит
              // initialValue с первой отрисовки и показывает не тот пункт,
              // который реально выбран после автоподстановки в _pick().
              key: ValueKey('pdf_tool_$_tool'),
              initialValue: _tool,
              decoration: InputDecoration(labelText: tr('Что сделать')),
              items: [
                for (final e in PdfToolsService.tools.entries)
                  if (_allowedTools.contains(e.key))
                    DropdownMenuItem(value: e.key, child: Text(tr(e.value))),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _tool = v ?? _tool;
                        // Выбранный файл при смене инструмента НЕ стираем:
                        // пользователь уже приложил файл и хочет просто
                        // выбрать другой способ обработки (отзыв 20.11,
                        // 17:27 — «файл куда-то пропал пока я выбирал»).
                        if (_single && _files.length > 1) _files = _files.take(1).toList();
                        _result = null;
                        _message = null;
                      }),
            ),
            ..._optionsUi(theme),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.attach_file),
                  label: Text(tr('Выбрать файлы')),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                // Кнопка больше не гаснет на пустом списке: раньше она
                // выглядела сломанной (отзыв 20.11). Теперь нажатие
                // объясняет, чего не хватает (см. _run).
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt),
                label: Text(tr('Обработать')),
              ),
            ]),
            if (_files.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final f in _files)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(f.bytes.length / 1024).round()} КБ'),
                ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: theme.textTheme.bodyMedium),
            ],
            if (_result != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share),
                label: Text(tr('Поделиться результатом')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

