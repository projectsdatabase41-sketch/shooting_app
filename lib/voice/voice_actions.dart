import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../models/coach_note.dart';
import '../models/target_face.dart';
import '../services/ai_settings.dart';
import '../services/coach_notes_repository.dart';
import '../services/local_db_service.dart';
import '../services/web_search_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_route.dart';
import 'voice_grammar.dart';

/// Действия голосового управления, которые доступны на любой странице. Показываются поверх текущего экрана.

/// «Найди в интернете …»: запрос идёт через поиск Gemini (нужен ключ в настройках ИИ), ответ показывается в шторке
/// на этой же странице структурированно (заголовок, пункты, источники).
Future<String> runWebSearch(
    BuildContext ctx, LocalDbService db, String? query) async {
  final q = query?.trim() ?? '';
  if (q.isEmpty) return tr('Скажите, что искать: «найди в интернете …»');
  final service = WebSearchService(AiSettings(db));
  if (!service.configured)
    return tr('Для поиска в интернете нужен ключ Gemini: Настройки → ИИ');
  final future = service.search(q, structured: true);
  await showGlassSheet<void>(
    context: ctx,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => _WebAnswerSheet(query: q, future: future),
  );
  return tr('Поиск: {q}', {'q': q});
}

class _WebAnswerSheet extends StatelessWidget {
  final String query;
  final Future<({String text, List<({String title, String url})> sources})>
      future;
  const _WebAnswerSheet({required this.query, required this.future});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: FutureBuilder<
            ({String text, List<({String title, String url})> sources})>(
          future: future,
          builder: (context, snap) {
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                Text(tr('В интернете: {q}', {'q': query}),
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                if (snap.connectionState != ConnectionState.done)
                  const Center(
                      child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator()))
                else if (snap.hasError)
                  Text(friendlyError(snap.error!))
                else ...[
                  SelectableText(snap.data!.text,
                      style: theme.textTheme.bodyMedium),
                  if (snap.data!.sources.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(tr('Источники'), style: theme.textTheme.labelLarge),
                    for (final s in snap.data!.sources.take(8))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link, size: 18),
                        title: Text(s.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => launchUrl(Uri.parse(s.url),
                            mode: LaunchMode.externalApplication),
                      ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// «Запиши в заметки …»: запись в модуль «Заметки».
String addDiaryNoteByVoice(LocalDbService db, String? text) {
  final t = text?.trim() ?? '';
  if (t.isEmpty) return tr('Скажите, что записать: «запиши в заметки …»');
  final topic = t.length <= 40 ? t : '${t.substring(0, 40).trimRight()}…';
  CoachNotesRepository(db).add(CoachNote(
      id: const Uuid().v4(),
      topic: topic,
      content: t,
      createdAt: DateTime.now()));
  return tr('Записано в заметки');
}

/// «Создай упражнение …»: черновик показывается на подтверждение, без подтверждения ничего не создаётся.
Future<String> createExerciseByVoice(BuildContext ctx, VoiceIntent i) async {
  final store = Provider.of<AppDataStore>(ctx, listen: false);
  final shots = (i.shots ?? 10).clamp(1, 300);
  final face = TargetFace.byCode(i.face ?? 'rifle_10m');
  final name = (i.text != null && i.text!.trim().isNotEmpty)
      ? i.text!.trim()
      : tr('{n} выстрелов, {face}', {'n': shots, 'face': face.name});
  final ok = await showGlassDialog<bool>(
    context: ctx,
    builder: (d) => AlertDialog(
      title: Text(tr('Создать упражнение?')),
      content: Text(tr('«{name}»: {n} выстрелов, серия по 10, мишень {face}',
          {'name': name, 'n': shots, 'face': face.name})),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr('Отмена'))),
        FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr('Создать'))),
      ],
    ),
  );
  if (ok != true) return tr('Отменено');
  store.createExercise(
      name: name,
      targetFaceCode: face.code,
      totalShots: shots,
      seriesSize: shots < 10 ? shots : 10);
  return tr('Упражнение создано');
}
