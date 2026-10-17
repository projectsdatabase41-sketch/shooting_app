import 'package:flutter/material.dart';
import 'app_backdrop.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../logic/ai_context.dart';
import '../models/training_session.dart';
import '../screens/ai_chat_screen.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../state/app_data_store.dart';

/// Ассистент один для всех ролей. Если вы ещё и тренер, над чатом полоса
/// «Чьи данные»: «Я» или один из ваших спортсменов — ассистент видит
/// тренировки выбранного человека и не путает их с чужими (в контексте
/// помечено, кому они принадлежат).
class AssistantTab extends StatefulWidget {
  const AssistantTab({super.key});

  @override
  State<AssistantTab> createState() => _AssistantTabState();
}

class _AssistantTabState extends State<AssistantTab> {
  late final CoachAccessService _access = CoachAccessService(context.read<AppDataStore>().db);
  late final List<CoachAthlete> _athletes = _access.listAthletes();
  CoachAthlete? _owner; // null — я
  bool _loading = false;
  String? _error;
  final Map<String, ({List<TrainingSession> sessions, String Function(TrainingSession) nameOf})> _cache = {};

  Future<void> _pick(CoachAthlete? a) async {
    setState(() {
      _owner = a;
      _error = null;
    });
    if (a == null || _cache.containsKey(a.id)) return;
    setState(() => _loading = true);
    try {
      final exercises = await _access.fetchExercises(athlete: a);
      final packages = await _access.fetchSessions(athlete: a);
      final shots = <String, List<Map<String, dynamic>>>{};
      for (final p in packages) {
        final id = '${p['id']}';
        shots[id] = await _access.fetchShots(id, athlete: a);
      }
      final sessions = mapCoachSessions(packages, exercises, shots).where((s) => s.shots.isNotEmpty).toList()
        ..sort((x, y) => (y.startedAt ?? DateTime(0)).compareTo(x.startedAt ?? DateTime(0)));
      _cache[a.id] = (sessions: sessions, nameOf: coachExerciseNameOf(exercises));
    } catch (_) {
      _error = tr('Не удалось загрузить данные спортсмена: проверьте связь и доступ');
      _owner = null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final showPicker = store.isCoach && _athletes.isNotEmpty;
    final data = _owner == null ? null : _cache[_owner!.id];
    final chat = AiChatScreen(
      key: ValueKey(_owner?.id ?? 'me'),
      scope: AiScope.general,
      coachMode: store.isCoach,
      sessionsOverride: data?.sessions,
      exerciseNameOfOverride: data?.nameOf,
      ownerLabel: data == null ? null : _owner!.name,
    );
    if (!showPicker) return AppBackdrop(kind: 'ai', child: chat);
    return AppBackdrop(kind: 'ai', child: Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 6, 12, 0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(tr('Я')), selected: _owner == null, onSelected: (_) => _pick(null)),
            ),
            for (final a in _athletes)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(a.name), selected: _owner?.id == a.id, onSelected: (_) => _pick(a)),
              ),
          ]),
        ),
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: chat)),
    ]));
  }
}
