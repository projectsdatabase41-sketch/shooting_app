import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/ai_context.dart';
import '../models/training_session.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import 'ai_chat_screen.dart';

/// "Чат с ИИ" тренера (раздел 8 ТЗ) — как у спортсмена, но с выбором
/// спортсмена сверху (данные для ассистента — тренировки ВЫБРАННОГО
/// спортсмена, а не самого тренера), и ассистент вправе предлагать
/// заметку в дневник тренера (`AiChatScreen.coachMode`).
class CoachAiChatScreen extends StatefulWidget {
  const CoachAiChatScreen({super.key});

  @override
  State<CoachAiChatScreen> createState() => _CoachAiChatScreenState();
}

class _CoachAiChatScreenState extends State<CoachAiChatScreen> {
  late final CoachAccessService _access;
  List<CoachAthlete> _athletes = [];
  CoachAthlete? _athlete;
  bool _loading = false;
  List<TrainingSession> _sessions = [];
  String Function(TrainingSession) _nameOf = (_) => 'Упражнение';

  @override
  void initState() {
    super.initState();
    _access = CoachAccessService(context.read<AppDataStore>().db);
    _athletes = _access.listAthletes();
    if (_athletes.isNotEmpty) {
      _athlete = _athletes.first;
      _load();
    }
  }

  Future<void> _load() async {
    final athlete = _athlete;
    if (athlete == null) return;
    setState(() => _loading = true);
    try {
      final exercises = await _access.fetchExercises(athlete: athlete);
      final packages = await _access.fetchSessions(athlete: athlete);
      final shotsByPackageId = <String, List<Map<String, dynamic>>>{};
      for (final p in packages) {
        final id = '${p['id']}';
        shotsByPackageId[id] = await _access.fetchShots(id, athlete: athlete);
      }
      if (!mounted) return;
      setState(() {
        _sessions = mapCoachSessions(packages, exercises, shotsByPackageId);
        _nameOf = coachExerciseNameOf(exercises);
      });
    } catch (_) {
      // Ошибку сети ассистенту показывать незачем — он просто останется
      // без данных этого спортсмена и ответит на общие вопросы.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ассистент')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _athletes.isEmpty
                ? const EmptyState(icon: Icons.groups_outlined, text: 'Сначала добавьте спортсмена')
                : DropdownButtonFormField<String>(
                    initialValue: _athlete?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Спортсмен'),
                    items: [for (final a in _athletes) DropdownMenuItem(value: a.id, child: Text(a.name))],
                    onChanged: (v) {
                      setState(() => _athlete = _athletes.firstWhere((a) => a.id == v));
                      _load();
                    },
                  ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _athletes.isEmpty
                ? const SizedBox()
                : AiChatScreen(
                    key: ValueKey(_athlete?.id),
                    scope: AiScope.general,
                    embedded: true,
                    coachMode: true,
                    sessionsOverride: _sessions,
                    exerciseNameOfOverride: _nameOf,
                  ),
          ),
        ],
      ),
    );
  }
}
