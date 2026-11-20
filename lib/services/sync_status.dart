import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../state/app_data_store.dart';
import 'supabase_auth_service.dart';
import 'supabase_service.dart';

/// Фоновая синхронизация с облаком: запускается из настроек, но живёт
/// отдельно от экрана — можно уйти на другую страницу, синхронизация
/// продолжается, а в углу главного экрана виден индикатор (отзыв 18.11, 11:08).
class SyncStatus {
  SyncStatus._();

  static final ValueNotifier<SyncState> state =
      ValueNotifier<SyncState>(const SyncState.idle());

  static bool get running => state.value.running;

  /// [kind] — `pull` (из облака), `push` (в облако) или `recover`
  /// (снять локальные пометки удалённого и подтянуть всё заново).
  static Future<void> run(AppDataStore store, String kind) async {
    if (running) return;
    state.value = SyncState(kind: kind, running: true);
    try {
      final sync = SupabaseSyncService(SupabaseAuthService(store.db));
      if (kind == 'recover') store.clearLocalTombstones();
      String message;
      if (kind == 'push') {
        final deleted = await sync.pushDeletions(store);
        final sent = await sync.push(store);
        final parts = <String>[];
        if (deleted > 0) parts.add(tr('удалено: {deleted}', {'deleted': deleted}));
        if (sent > 0) parts.add(tr('отправлено: {pushed}', {'pushed': sent}));
        message = parts.isEmpty
            ? tr('Готово, новых данных не было')
            : tr('Готово — {p}', {'p': parts.join(', ')});
      } else {
        final r = await sync.pull(store);
        final parts = <String>[];
        if (r.pulledSessions > 0) parts.add(tr('получено тренировок: {p}', {'p': r.pulledSessions}));
        if (r.pulledExercises > 0) parts.add(tr('упражнений: {p}', {'p': r.pulledExercises}));
        if (r.pulledComments > 0) parts.add(tr('комментариев: {p}', {'p': r.pulledComments}));
        if (r.removedDuplicates > 0)
          parts.add(tr('убрано дублей и пустых: {n}', {'n': r.removedDuplicates}));
        message = parts.isEmpty
            ? tr('Готово, новых данных не было')
            : tr('Готово — {p}', {'p': parts.join(', ')});
      }
      _finish(SyncState(kind: kind, running: false, done: true, message: message, at: DateTime.now()));
    } catch (e) {
      _finish(SyncState(
          kind: kind, running: false, failed: true, message: friendlyError(e), at: DateTime.now()));
    }
  }

  static void _finish(SyncState s) {
    state.value = s;
    // Индикатор в углу гаснет через две секунды после завершения.
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!state.value.running && state.value.at == s.at) {
        state.value = const SyncState.idle();
      }
    });
  }
}

class SyncState {
  /// `pull` из облака, `push` в облако, `recover` — восстановление.
  final String kind;
  final bool running;
  final bool done;
  final bool failed;
  final String? message;
  final DateTime? at;

  const SyncState({
    this.kind = '',
    this.running = false,
    this.done = false,
    this.failed = false,
    this.message,
    this.at,
  });

  const SyncState.idle() : this();

  bool get visible => running || done || failed;

  String get title => switch (kind) {
        'push' => tr('Отправка в облако'),
        'recover' => tr('Восстановление из облака'),
        _ => tr('Загрузка из облака'),
      };
}
