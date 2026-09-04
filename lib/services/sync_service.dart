import '../models/training_session.dart';
import 'supabase_service.dart';

enum SyncState { idle, syncing, error, done }

/// Ручная синхронизация, кнопкой "Синхронизировать сейчас" (раздел 2/9
/// ТЗ). Отправляется вся тренировка целиком, атомарно. Без автоматики,
/// без "только по Wi-Fi" — сознательно убрано как лишнее усложнение.
class SyncService {
  final SupabaseService supabaseService;

  SyncService(this.supabaseService);

  SyncState state = SyncState.idle;
  String? lastError;

  Future<void> syncNow(List<TrainingSession> unsyncedSessions) async {
    state = SyncState.syncing;
    lastError = null;
    try {
      for (final session in unsyncedSessions) {
        await supabaseService.pushSession(session);
      }
      state = SyncState.done;
    } catch (e) {
      state = SyncState.error;
      lastError = e.toString();
      rethrow;
    }
  }
}
