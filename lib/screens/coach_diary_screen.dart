import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../widgets/empty_state.dart';

/// Экран тренера — "дневник" (раздел 8 ТЗ). НЕ список тренировок,
/// которые тренер создаёт сам — список ПОДКЛЮЧЁННЫХ спортсменов, тап →
/// список их тренировок по датам → экран мишени в режиме только-чтение.
///
/// Реальное чтение тренера из проекта спортсмена по токену — раздел 12
/// ТЗ п.3, осознанно вне объёма: здесь честная заглушка (пустой список),
/// а не выдуманные данные.
class CoachDiaryScreen extends StatelessWidget {
  const CoachDiaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Дневник')),
      body: FutureBuilder(
        future: DemoSupabaseService().fetchSharedSessions(''),
        builder: (context, snapshot) {
          return const EmptyState(
            icon: Icons.groups_outlined,
            text: 'Список подключённых спортсменов появится здесь после реального '
                'подключения к Supabase (раздел 12 ТЗ, п.3) — сейчас честная '
                'заглушка вместо выдуманных данных.',
          );
        },
      ),
    );
  }
}
