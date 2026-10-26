import 'dart:convert';

import '../services/ai_service.dart';
import 'voice_grammar.dart';

/// ИИ-помощник голосового управления: понимает фразы, которые не разобрала грамматика. Работает на отдельной модели
/// (`task: 'voice'`) и только ВЫБИРАЕТ действие из закрытого списка — ничего не пишет от себя и не отвечает текстом.
/// Любой ответ вне списка отбрасывается.
class VoiceAi {
  VoiceAi(this.service);

  final AiService service;

  /// Описание экрана и список действий — отдельно для каждого режима: помощник выбирает только из того, что на этом
  /// экране возможно, и вытаскивает параметры из слов человека (ничего не придумывает).
  static String systemFor(String? mode) {
    final actions = <String>[
      'open {target: one of ${VoiceGrammar.sections.values.toSet().join('|')}} — open a section',
      'back — go back',
      'webSearch {query} — search the internet (the user says "find on the internet …")',
      'addDiaryNote {text} — write to the Notes module ("write to notes …")',
      'createExercise {shots: integer, face: rifle_10m|rifle_50m|pistol_10m|pistol_25m, text: name or null} — create an exercise',
      'askAi {text} — ask the assistant a question',
    ];
    var screen = 'the main screen';
    if (mode == VoiceMode.training) {
      screen = 'an open TRAINING screen (the shooter is shooting at a target)';
      actions.addAll([
        'placeShot {score: number 0..10.9, hour: 0..12, text: note or null} — mark a shot: "ten five at 5 o\'clock, jerked my finger" = score 10.5, hour 5, text "jerked my finger"',
        'trainingStart, trainingPause, trainingResume, trainingFinish, undoShot, focusMode',
        'addNote {text} — note to the last shot',
      ]);
    } else if (mode == VoiceMode.chat) {
      screen = 'an open CHAT with a person';
      actions.add(
          'chatSearch {query: key words in base form (e.g. "долг" for "долгами"), filter: photo|file|audio|video|null} — search this chat');
    } else if (mode == VoiceMode.finalRun) {
      screen = 'a FINAL (shooting competition) screen';
      actions.add('finalReady — the shooter is ready');
    }
    return '''You map a spoken command of a shooting-sports app to ONE action. The user is on $screen.
Reply with JSON only: {"action":"<id>","target":null,"text":null,"score":null,"hour":null,"query":null,"filter":null,"shots":null,"face":null}.
Allowed actions:
${actions.map((a) => '- $a').join('\n')}
Copy the user's own words into "text"/"query" unchanged (except base-form key words for chatSearch). If the phrase is not a command of this screen, reply {"action":"none"}. Never invent actions, never explain.''';
  }

  static const _faces = {'rifle_10m', 'rifle_50m', 'pistol_10m', 'pistol_25m'};
  static const _filters = {'photo', 'file', 'audio', 'video'};

  /// Разбор ответа модели в команду; `null` — «не команда», ответ вне списка или с недопустимыми параметрами.
  static VoiceIntent? parseReply(String reply, {String? mode}) {
    final start = reply.indexOf('{'), end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final j =
          jsonDecode(reply.substring(start, end + 1)) as Map<String, dynamic>;
      final action = VoiceAction.values
          .where((a) => a.name == '${j['action']}')
          .firstOrNull;
      if (action == null) return null;
      String? s(String k) {
        final v = j[k];
        if (v == null) return null;
        final t = '$v'.trim();
        return t.isEmpty || t == 'null' ? null : t;
      }

      double? d(String k) =>
          j[k] is num ? (j[k] as num).toDouble() : double.tryParse(s(k) ?? '');
      final text = s('text'),
          query = s('query'),
          filter = s('filter'),
          target = s('target');
      switch (action) {
        case VoiceAction.open:
          if (!VoiceGrammar.sections.values.contains(target)) return null;
          return VoiceIntent(action, target: target);
        case VoiceAction.askAi:
        case VoiceAction.addDiaryNote:
          if (text == null && action == VoiceAction.askAi) return null;
          return VoiceIntent(action, text: text);
        case VoiceAction.webSearch:
          return query == null ? null : VoiceIntent(action, query: query);
        case VoiceAction.createExercise:
          final f = s('face');
          final n = d('shots')?.round();
          return VoiceIntent(action,
              shots: (n != null && n >= 1 && n <= 300) ? n : null,
              face: _faces.contains(f) ? f : 'rifle_10m',
              text: text);
        case VoiceAction.placeShot:
          if (mode != VoiceMode.training) return null;
          final score = d('score'), hour = d('hour');
          if (score == null ||
              hour == null ||
              score < 0 ||
              score > 10.9 ||
              hour < 0 ||
              hour > 12) return null;
          return VoiceIntent(action, score: score, hour: hour, text: text);
        case VoiceAction.chatSearch:
          if (mode != VoiceMode.chat) return null;
          final f = _filters.contains(filter) ? filter : null;
          if (query == null && f == null) return null;
          return VoiceIntent(action,
              query: query == null
                  ? null
                  : query
                      .split(RegExp(r'\s+'))
                      .map(VoiceGrammar.searchStem)
                      .join(' '),
              filter: f);
        case VoiceAction.addNote:
          return VoiceIntent(action, text: text);
        default:
          return VoiceIntent(action);
      }
    } catch (_) {
      return null;
    }
  }

  Future<VoiceIntent?> interpret(String phrase, {String? mode}) async {
    try {
      final r = await service.ask(
        task: 'voice',
        systemPrompt: systemFor(mode),
        contextBlock: '',
        history: [(role: 'user', text: phrase)],
        json: true,
        rotateKeys: true,
      );
      return parseReply(r.text, mode: mode);
    } catch (_) {
      return null;
    }
  }
}
