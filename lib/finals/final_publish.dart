import '../finals/bot.dart';
import '../finals/champions_service.dart';
import '../finals/plausibility.dart';
import '../services/chat_auth_service.dart';
import '../services/supabase_auth_service.dart';
import '../services/user_profile.dart';
import '../state/app_data_store.dart';

/// Итог публичного финала уходит в таблицу чемпионов сам, от каждого спортсмена.
/// Без подтверждения: если по своим тренировкам результат правдоподобен — публикуется сразу,
/// иначе уходит на подпись связанному тренеру; нет тренера — тихо ничего (можно вручную из итогов).
/// Возвращает `null`, если отправлено, или причину пропуска.
Future<String?> autoPublishFinal(AppDataStore store, Map<String, dynamic> record) async {
  final auth = ChatAuthService(store.db);
  if (!auth.isSignedIn) return 'нет входа в мессенджер';
  final st = (record['standings'] as List).cast<Map<String, dynamic>>();
  final me = st.where((e) => e['user'] == true).firstOrNull;
  if (me == null) return 'не участник';
  final face = record['face'] as String;
  final shots = (record['shots'] as List).cast<Map<String, dynamic>>();
  final mine = [for (final s in shots) if (s['who'] == me['id'] && s['so'] != true) s];
  if (mine.isEmpty) return 'нет выстрелов';
  final scores = [for (final s in mine) (s['s'] as num).toDouble()];
  final training = [
    for (final se in store.sessions)
      if (se.targetFaceCode == face) for (final sh in se.countingShots) sh.score
  ];
  final verdict = checkPlausibility(training, scores);
  if (verdict == Plausibility.suspicious) return 'результат выше тренировок';
  final hasPoints = mine.any((s) => (s['x'] as num) != 0 || (s['y'] as num) != 0);
  final stt = ShotStats.fromPoints([for (final s in mine) ((s['x'] as num).toDouble(), (s['y'] as num).toDouble())]);
  final stats = {'mx': stt.mx, 'my': stt.my, 'sx': stt.sx, 'sy': stt.sy, 'n': hasPoints ? stt.n : 0, 'face': face};
  final profile = '${UserProfile.firstNameOf(store.db)} ${UserProfile.lastNameOf(store.db)}'.trim();
  final name = profile.isNotEmpty ? profile : auth.nickname;
  final selfOk = training.length >= ChampionsService.minTrainingShotsForSelf && verdict == Plausibility.ok;
  String? coachId;
  if (!selfOk) {
    final coaches = await SupabaseAuthService(store.db).fetchLinkedCoaches();
    if (coaches.isEmpty) return 'нет тренера для подписи';
    coachId = coaches.first.chatUserId;
  }
  return ChampionsService(auth).publish(record, name: name, coachId: coachId, selfVerified: selfOk, stats: stats, protocolShots: scores);
}
