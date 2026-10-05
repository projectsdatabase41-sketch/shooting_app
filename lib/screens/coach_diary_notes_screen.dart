import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/coach_note.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/coach_notes_repository.dart';
import '../state/app_data_store.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import '../widgets/swipe_to_delete.dart';
import '../logic/save_file.dart';
import 'pdf_viewer_screen.dart';
import 'photo_viewer_screen.dart';
import '../i18n/i18n.dart';

/// "Дневник" тренера (раздел 8 ТЗ) — темы и заметки, не привязан ни к
/// одному спортсмену. Заметки создаются вручную здесь ИЛИ ассистентом
/// из "Чат с ИИ" (см. `AiChatScreen` кнопку "Сохранить в дневник"), а
/// здесь же можно попросить ИИ написать/дополнить заметку напрямую —
/// одноразовый запрос к модели, без общей истории чата.
class CoachDiaryNotesScreen extends StatefulWidget {
  const CoachDiaryNotesScreen({super.key});

  @override
  State<CoachDiaryNotesScreen> createState() => _CoachDiaryNotesScreenState();
}

class _CoachDiaryNotesScreenState extends State<CoachDiaryNotesScreen> {
  late final CoachNotesRepository _repo;
  late final AiSettings _aiSettings;
  List<CoachNote> _notes = [];

  @override
  void initState() {
    super.initState();
    final db = context.read<AppDataStore>().db;
    _repo = CoachNotesRepository(db);
    _aiSettings = AiSettings(db);
    _reload();
  }

  void _reload() => setState(() => _notes = _repo.list());

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yy HH:mm');
    final top = MediaQuery.paddingOf(context).top + GlassHeader.height;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Дневник'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: _notes.isEmpty
          ? EmptyState(
              icon: Icons.menu_book_outlined, text: tr('Заметок пока нет'))
          : Stack(
              children: [
                Positioned.fill(
                    child: ListView.builder(
                  padding: EdgeInsets.only(top: top, bottom: 88),
                  itemCount: _notes.length,
                  itemBuilder: (context, i) {
                    final n = _notes[i];
                    return SwipeToDelete(
                      itemKey: n.id,
                      title: tr('Удалить заметку?'),
                      message: tr(
                          '«{topic}» будет удалена без возможности восстановить.',
                          {'topic': n.topic}),
                      onConfirmed: () {
                        _repo.delete(n.id);
                        _reload();
                      },
                      child: ListTile(
                        // Дата/время — слева, мелким, вместо подписи снизу
                        // (решение пользователя): тема важнее и читается
                        // крупным шрифтом.
                        leading: SizedBox(
                          width: 52,
                          child: Text(
                            df.format(n.createdAt.toLocal()),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                        title: Text(n.topic,
                            style: Theme.of(context).textTheme.titleMedium),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _NoteScreen(
                                note: n, repo: _repo, aiSettings: _aiSettings),
                          ));
                          _reload();
                        },
                      ),
                    );
                  },
                )),
                Positioned.fill(child: EdgeShade(top: top + 16)),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _openAddDialog(BuildContext context) async {
    final saved = await showDialog<CoachNote>(
      context: context,
      builder: (ctx) => _AddNoteDialog(aiSettings: _aiSettings),
    );
    if (saved == null) return;
    _repo.add(saved);
    _reload();
  }
}

/// Диалог создания заметки — либо вручную (тема + текст), либо кнопкой
/// "AI" рядом с темой: тогда тема необязательна (её придумает ИИ), а
/// текст — задание, что написать.
class _AddNoteDialog extends StatefulWidget {
  final AiSettings aiSettings;
  const _AddNoteDialog({required this.aiSettings});

  @override
  State<_AddNoteDialog> createState() => _AddNoteDialogState();
}

class _AddNoteDialogState extends State<_AddNoteDialog> {
  final _topicCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  bool _aiMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _topicCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) return;

    if (!_aiMode) {
      final topic = _topicCtrl.text.trim();
      if (topic.isEmpty) return;
      Navigator.of(context).pop(CoachNote(
        id: const Uuid().v4(),
        topic: topic,
        content: content,
        createdAt: DateTime.now(),
      ));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final reply = await AiService(widget.aiSettings).ask(
        task: 'note_create',
        json: true,
        systemPrompt:
            'Ты помогаешь тренеру по стрельбе вести дневник в приложении. '
            'По заданию тренера придумай короткую тему заметки (3-6 слов) и напиши сам текст. '
            'Используй ТОЛЬКО то, что написал тренер в задании ниже — никаких данных о '
            'тренировках, выстрелах или заметках спортсмена ты не знаешь и не используешь, '
            'здесь только формулировка текста по заданию. '
            'Тема и текст — на том же языке, на котором тренер написал задание. '
            'Ответь СТРОГО одним JSON-объектом без пояснений, без markdown-разметки: '
            '{"topic":"...","content":"..."}',
        contextBlock: '',
        history: [(role: 'user', text: content)],
      );
      final parsed = _extractJson(reply.text);
      if (!mounted) return;
      Navigator.of(context).pop(CoachNote(
        id: const Uuid().v4(),
        topic: '${parsed?['topic'] ?? 'Заметка'}'.trim(),
        content: '${parsed?['content'] ?? reply.text}'.trim(),
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Новая заметка')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _topicCtrl,
                    enabled: !_aiMode,
                    decoration: InputDecoration(
                        labelText: _aiMode ? tr('Я сам заполню') : tr('Тема')),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip:
                      _aiMode ? tr('Заполнить вручную') : tr('Придумает ИИ'),
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  isSelected: _aiMode,
                  onPressed: () => setState(() => _aiMode = !_aiMode),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contentCtrl,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                  labelText: _aiMode ? tr('Что требуется?') : tr('Текст')),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Отмена'))),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('Сохранить')),
        ),
      ],
    );
  }
}

class _NoteScreen extends StatefulWidget {
  final CoachNote note;
  final CoachNotesRepository repo;
  final AiSettings aiSettings;

  const _NoteScreen(
      {required this.note, required this.repo, required this.aiSettings});

  @override
  State<_NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<_NoteScreen> {
  late final TextEditingController _content;
  bool _aiBusy = false;
  String? _error;
  late List<CoachNoteFile> _files = widget.repo.files(widget.note.id);

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.note.content);
  }

  static const _maxFileBytes = 15 * 1024 * 1024;

  /// Прикрепить файл к ЭТОЙ заметке: PDF, Word, TXT или изображение.
  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'doc',
        'docx',
        'txt',
        'jpg',
        'jpeg',
        'png',
        'webp'
      ],
      withData: true,
    );
    final f = result?.files.single;
    final bytes = f?.bytes;
    if (f == null || bytes == null || !mounted) return;
    if (bytes.length > _maxFileBytes) {
      setState(
          () => _error = tr('Файл больше 15 МБ — он не поместится в дневник'));
      return;
    }
    widget.repo.addFile(widget.note.id, const Uuid().v4(), f.name, null, bytes);
    setState(() {
      _error = null;
      _files = widget.repo.files(widget.note.id);
    });
  }

  Future<void> _openFile(CoachNoteFile f) async {
    final bytes = widget.repo.fileBytes(f.id);
    if (bytes == null) return;
    if (f.isImage) {
      await PhotoViewerScreen.open(context, MemoryImage(bytes));
    } else if (f.isPdf) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PdfViewerScreen(bytes: bytes, fileName: f.name)));
    } else if (f.isText) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(f.name),
          content: SingleChildScrollView(
              child: SelectableText(utf8.decode(bytes, allowMalformed: true))),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(tr('Закрыть')))
          ],
        ),
      );
    } else {
      // Word и прочее встроенно не показать — сохраняем/открываем системой.
      await saveBytes(Uint8List.fromList(bytes), f.name);
    }
  }

  IconData _fileIcon(CoachNoteFile f) => f.isImage
      ? Icons.image_outlined
      : f.isPdf
          ? Icons.picture_as_pdf_outlined
          : f.isText
              ? Icons.text_snippet_outlined
              : Icons.description_outlined;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  void _save() {
    widget.repo.update(widget.note.id,
        topic: widget.note.topic, content: _content.text.trim());
  }

  /// Кнопка "AI" в заметке: пишешь задание в отдельном диалоге, ответ
  /// ассистента (только содержимое, без рассуждений) заменяет текст
  /// заметки целиком.
  Future<void> _editWithAi() async {
    final instruction = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text(tr('Задание для ИИ')),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
                hintText: tr('Что изменить или дописать в заметке')),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(tr('Отправить')),
            ),
          ],
        );
      },
    );
    if (instruction == null || instruction.isEmpty) return;

    setState(() {
      _aiBusy = true;
      _error = null;
    });
    try {
      final reply = await AiService(widget.aiSettings).ask(
        task: 'note_edit',
        systemPrompt:
            'Ты помогаешь тренеру по стрельбе редактировать заметку дневника в приложении. '
            'Тебе дан текущий текст заметки и задание, что в нём изменить или дописать. '
            'Используй ТОЛЬКО текст заметки и само задание — никаких данных о тренировках, '
            'выстрелах или заметках спортсмена ты не знаешь и не используешь. '
            'Язык — тот же, что у текущего текста заметки (меняй язык, только если задание прямо об этом просит). '
            'Ответь ТОЛЬКО новым полным текстом заметки целиком — без пояснений, без рассуждений, '
            'без markdown-разметки и без пересказа задания.',
        contextBlock: 'Текущий текст заметки:\n${_content.text}',
        history: [(role: 'user', text: instruction)],
      );
      if (!mounted) return;
      setState(() => _content.text = reply.text.trim());
      _save();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: GlassHeader(
          title: Text(widget.note.topic,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          actions: [
            GlassCircleButton(
              tooltip: tr('Помощь ИИ'),
              icon: _aiBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              onTap: _aiBusy ? null : _editWithAi,
            ),
            GlassCircleButton(
              tooltip: tr('Удалить'),
              icon: const Icon(Icons.delete_outline),
              onTap: () {
                widget.repo.delete(widget.note.id);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              DateFormat('dd.MM.yyyy HH:mm')
                  .format(widget.note.createdAt.toLocal()),
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 12),
            // Заметка не заблокирована — правится прямо здесь, без
            // отдельного режима редактирования (решение пользователя).
            TextField(
              controller: _content,
              maxLines: null,
              minLines: 4,
              decoration: const InputDecoration(border: InputBorder.none),
              onChanged: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (widget.note.chart != null) ...[
              const SizedBox(height: 12),
              AiChartView(spec: widget.note.chart!),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                    child: Text(tr('Файлы'),
                        style: Theme.of(context).textTheme.titleSmall)),
                TextButton.icon(
                  onPressed: _attach,
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: Text(tr('Прикрепить')),
                ),
              ],
            ),
            for (final f in _files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_fileIcon(f)),
                title:
                    Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${(f.size / 1024).ceil()} ${tr('КБ')}'),
                onTap: () => _openFile(f),
                trailing: IconButton(
                  tooltip: tr('Удалить'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    widget.repo.deleteFile(f.id);
                    setState(() => _files = widget.repo.files(widget.note.id));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Достаёт первый JSON-объект из текста ответа модели — на случай, если
/// она обернула его в ```json-блок или добавила пояснение до/после.
Map<String, dynamic>? _extractJson(String raw) {
  final match = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(match.group(0)!);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
