import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/ai_context.dart';
import '../screens/ai_chat_screen.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../state/app_data_store.dart';
import 'app_backdrop.dart';

/// Ассистент один для всех: переключателей ролей и «чьи данные» нет. Он видит
/// и свои тренировки, и тренировки подключённых спортсменов (если вы тренер) —
/// в контексте они разложены по именам, поэтому людей не путает.
class AssistantTab extends StatefulWidget {
  const AssistantTab({super.key});

  @override
  State<AssistantTab> createState() => _AssistantTabState();
}

class _AssistantTabState extends State<AssistantTab> {
  List<AiAthleteData> _athletes = const [];

  @override
  void initState() {
    super.initState();
    _loadAthletes();
  }

  /// Данные спортсменов подгружаются в фоне; пока их нет (или нет связи),
  /// ассистент работает со своими данными.
  Future<void> _loadAthletes() async {
    final access = CoachAccessService(context.read<AppDataStore>().db);
    final list = access.listAthletes();
    final out = <AiAthleteData>[];
    for (final a in list) {
      try {
        final exercises = await access.fetchExercises(athlete: a);
        final packages = await access.fetchSessions(athlete: a);
        final shots = <String, List<Map<String, dynamic>>>{};
        for (final p in packages) {
          final id = '${p['id']}';
          shots[id] = await access.fetchShots(id, athlete: a);
        }
        out.add(AiAthleteData(a.name, mapCoachSessions(packages, exercises, shots), coachExerciseNameOf(exercises)));
      } catch (_) {
        // этого спортсмена пропускаем — остальные всё равно подключатся
      }
      if (!mounted) return;
      setState(() => _athletes = List.of(out));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    return AppBackdrop(
      kind: 'ai',
      child: AiChatScreen(
        scope: AiScope.general,
        coachMode: store.isCoach,
        athletes: _athletes,
      ),
    );
  }
}
