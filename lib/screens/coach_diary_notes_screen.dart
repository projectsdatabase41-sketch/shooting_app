import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/coach_note.dart';
import '../services/coach_notes_repository.dart';
import '../state/app_data_store.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/empty_state.dart';

/// "Дневник" тренера (раздел 8 ТЗ) — темы и заметки, не привязан ни к
/// одному спортсмену. Заметки создаются вручную здесь ИЛИ ассистентом
/// из "Чат с ИИ" (см. `AiChatScreen` кнопку "Сохранить в дневник").
class CoachDiaryNotesScreen extends StatefulWidget {
  const CoachDiaryNotesScreen({super.key});

  @override
  State<CoachDiaryNotesScreen> createState() => _CoachDiaryNotesScreenState();
}

class _CoachDiaryNotesScreenState extends State<CoachDiaryNotesScreen> {
  late final CoachNotesRepository _repo;
  List<CoachNote> _notes = [];

  @override
  void initState() {
    super.initState();
    _repo = CoachNotesRepository(context.read<AppDataStore>().db);
    _reload();
  }

  void _reload() => setState(() => _notes = _repo.list());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Дневник')),
      body: _notes.isEmpty
          ? const EmptyState(icon: Icons.menu_book_outlined, text: 'Заметок пока нет')
          : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, i) {
                final n = _notes[i];
                return ListTile(
                  title: Text(n.topic),
                  subtitle: Text(DateFormat('dd.MM.yyyy HH:mm').format(n.createdAt.toLocal())),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _NoteScreen(note: n, onDeleted: () {
                      _repo.delete(n.id);
                      _reload();
                    }),
                  )),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _openAddDialog(BuildContext context) async {
    final topicCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая заметка'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: topicCtrl, decoration: const InputDecoration(labelText: 'Тема')),
              const SizedBox(height: 8),
              TextField(
                controller: contentCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'Текст'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (saved != true) return;
    final topic = topicCtrl.text.trim();
    final content = contentCtrl.text.trim();
    if (topic.isEmpty || content.isEmpty) return;
    _repo.add(CoachNote(id: const Uuid().v4(), topic: topic, content: content, createdAt: DateTime.now()));
    _reload();
  }
}

class _NoteScreen extends StatelessWidget {
  final CoachNote note;
  final VoidCallback onDeleted;

  const _NoteScreen({required this.note, required this.onDeleted});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(note.topic),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              onDeleted();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            DateFormat('dd.MM.yyyy HH:mm').format(note.createdAt.toLocal()),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 12),
          SelectableText(note.content),
          if (note.chart != null) ...[
            const SizedBox(height: 12),
            AiChartView(spec: note.chart!),
          ],
        ],
      ),
    );
  }
}
