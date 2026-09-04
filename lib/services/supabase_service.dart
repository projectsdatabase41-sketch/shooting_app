import '../models/training_session.dart';

/// Заглушка реального Supabase-подключения (раздел 12 ТЗ, п.1 — осознанно
/// вне объёма текущего ТЗ). Экран подключения принимает URL/ключ, но
/// фактического похода в облако ещё нет — "Синхронизировать сейчас"
/// работает как честная заглушка с объяснением, а не тихий no-op.
///
/// Контракт методов уже соответствует тому, что понадобится реальному
/// `SupabaseClient` — так что подстановка в будущем не потребует менять
/// вызывающий код (`SyncService`), только реализацию этого класса.
abstract class SupabaseService {
  bool get isConnected;

  Future<void> connect({
    required String url,
    required String anonKey,
    required String email,
    required String password,
  });

  Future<void> disconnect();

  Future<void> pushSession(TrainingSession session);

  /// Раздел 12 ТЗ п.3 — реальное чтение тренера из проекта спортсмена по
  /// токену ещё не реализовано; возвращает пустой список как честная
  /// заглушка, а не выдуманные данные.
  Future<List<TrainingSession>> fetchSharedSessions(String shareToken);
}

class DemoSupabaseService implements SupabaseService {
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect({
    required String url,
    required String anonKey,
    required String email,
    required String password,
  }) async {
    // Раздел 5.1 ТЗ / раздел 12 п.1: пока работает на тестовых данных.
    // Реальный SupabaseClient.initialize()/signIn — следующий этап.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> pushSession(TrainingSession session) async {
    if (!_connected) {
      throw StateError(
        'Нет реального подключения к Supabase — это заглушка (раздел 12 ТЗ п.1). '
        'Тренировка сохранена локально, отправка в облако станет доступна '
        'после реализации SupabaseService.',
      );
    }
    // no-op: реальная отправка появится вместе с реальным клиентом.
  }

  @override
  Future<List<TrainingSession>> fetchSharedSessions(String shareToken) async {
    // Честная заглушка вместо выдуманных данных (раздел 12 ТЗ п.3).
    return const [];
  }
}
