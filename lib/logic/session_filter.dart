import 'dart:convert';
import 'dart:math' as math;

import '../models/training_session.dart';

/// Фильтр списка тренировок: результат, число выстрелов, СТП (средняя точка попадания), длительность, период,
/// наличие заметок к выстрелам. Пустой фильтр пропускает всё.
class SessionFilter {
  double? minScore, maxScore;
  int? minShots, maxShots;

  /// СТП: расстояние средней точки попадания от центра мишени, мм (не больше).
  double? maxStpMm;
  DateTime? from, to;
  int? minMinutes, maxMinutes;
  bool onlyWithNotes;

  SessionFilter({
    this.minScore,
    this.maxScore,
    this.minShots,
    this.maxShots,
    this.maxStpMm,
    this.from,
    this.to,
    this.minMinutes,
    this.maxMinutes,
    this.onlyWithNotes = false,
  });

  bool get isEmpty =>
      minScore == null &&
      maxScore == null &&
      minShots == null &&
      maxShots == null &&
      maxStpMm == null &&
      from == null &&
      to == null &&
      minMinutes == null &&
      maxMinutes == null &&
      !onlyWithNotes;

  /// Сколько условий задано (для значка на кнопке).
  int get count => [minScore, maxScore, minShots, maxShots, maxStpMm, from, to, minMinutes, maxMinutes].where((e) => e != null).length + (onlyWithNotes ? 1 : 0);

  /// Расстояние средней точки попадания зачётных выстрелов от центра, мм; `null` — выстрелов нет.
  static double? stpMm(TrainingSession s) {
    final shots = s.countingShots;
    if (shots.isEmpty) return null;
    final mx = shots.fold<double>(0, (a, b) => a + b.xMm) / shots.length;
    final my = shots.fold<double>(0, (a, b) => a + b.yMm) / shots.length;
    return math.sqrt(mx * mx + my * my);
  }

  /// Длительность тренировки в минутах; `null`, если она не завершена.
  static double? minutes(TrainingSession s) {
    final a = s.startedAt, b = s.finishedAt;
    return a == null || b == null ? null : b.difference(a).inSeconds / 60;
  }

  bool matches(TrainingSession s, {required bool hasNotes}) {
    final score = s.totalScore;
    if (minScore != null && score < minScore!) return false;
    if (maxScore != null && score > maxScore!) return false;
    final n = s.shots.length;
    if (minShots != null && n < minShots!) return false;
    if (maxShots != null && n > maxShots!) return false;
    if (maxStpMm != null) {
      final d = stpMm(s);
      if (d == null || d > maxStpMm!) return false;
    }
    final at = s.startedAt;
    if (from != null && (at == null || at.isBefore(from!))) return false;
    if (to != null && (at == null || at.isAfter(DateTime(to!.year, to!.month, to!.day, 23, 59, 59)))) return false;
    if (minMinutes != null || maxMinutes != null) {
      final m = minutes(s);
      if (m == null) return false;
      if (minMinutes != null && m < minMinutes!) return false;
      if (maxMinutes != null && m > maxMinutes!) return false;
    }
    if (onlyWithNotes && !hasNotes) return false;
    return true;
  }

  /// Разбор ответа ИИ-помощника: JSON с необязательными полями; всё непонятное отбрасывается.
  /// Поля: minScore, maxScore, minShots, maxShots, maxStp (мм), from, to (ГГГГ-ММ-ДД), minMinutes, maxMinutes, notes.
  static SessionFilter? fromAiReply(String reply) {
    final a = reply.indexOf('{'), b = reply.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final j = jsonDecode(reply.substring(a, b + 1)) as Map<String, dynamic>;
      double? d(String k) {
        final v = j[k];
        final x = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
        return x != null && x >= 0 && x < 100000 ? x : null;
      }

      DateTime? dt(String k) => DateTime.tryParse('${j[k] ?? ''}');
      final f = SessionFilter(
        minScore: d('minScore'),
        maxScore: d('maxScore'),
        minShots: d('minShots')?.round(),
        maxShots: d('maxShots')?.round(),
        maxStpMm: d('maxStp'),
        from: dt('from'),
        to: dt('to'),
        minMinutes: d('minMinutes')?.round(),
        maxMinutes: d('maxMinutes')?.round(),
        onlyWithNotes: j['notes'] == true,
      );
      return f.isEmpty ? null : f;
    } catch (_) {
      return null;
    }
  }

  /// Подсказка для ИИ: что понимать под полями и какой сегодня день.
  static String aiPrompt(DateTime today) => '''You turn a spoken/written request about shooting trainings into a filter.
Reply with JSON only, any of these keys (omit the rest): {"minScore":number,"maxScore":number,"minShots":int,"maxShots":int,"maxStp":number,"from":"YYYY-MM-DD","to":"YYYY-MM-DD","minMinutes":int,"maxMinutes":int,"notes":true}.
score = total result of the training; shots = number of shots; maxStp = max distance (mm) of the mean point of impact from the target center ("СТП"); minutes = duration; notes = only trainings that have notes on shots.
Today is ${today.toIso8601String().substring(0, 10)}. Resolve words like "за сентябрь", "на этой неделе" to dates. Never invent conditions the user did not say.''';
}
