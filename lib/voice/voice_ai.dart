import 'dart:convert';

import '../services/ai_service.dart';
import 'voice_grammar.dart';

/// ИИ-помощник голосового управления: понимает фразы, которые не разобрала грамматика. Работает на отдельной модели
/// (`task: 'voice'`) и только ВЫБИРАЕТ действие из закрытого списка — ничего не пишет от себя и не отвечает текстом.
/// Любой ответ вне списка отбрасывается.
class VoiceAi {
  VoiceAi(this.service);

  final AiService service;

  static final String _system = '''You map a spoken command (Russian or another language) of a shooting-sports app to ONE action.
Reply with JSON only: {"action": "<id>", "target": "<tab id or null>", "text": "<free text or null>"}.
Allowed action ids: ${[for (final a in VoiceAction.values) a.name].join(', ')}.
For "open" the target must be one of: ${VoiceGrammar.sections.values.toSet().join(', ')}.
"addNote" and "askAi" carry the user's own words in "text", unchanged.
If the phrase is not a command of this app, reply {"action": "none"}. Never invent actions, never explain.''';

  /// Разбор ответа модели в команду; `null` — «не команда» или ответ вне списка.
  static VoiceIntent? parseReply(String reply) {
    final start = reply.indexOf('{'), end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final j = jsonDecode(reply.substring(start, end + 1)) as Map<String, dynamic>;
      final name = '${j['action']}';
      final action = VoiceAction.values.where((a) => a.name == name).firstOrNull;
      if (action == null) return null;
      final target = j['target'] == null ? null : '${j['target']}';
      if (action == VoiceAction.open && !VoiceGrammar.sections.values.contains(target)) return null;
      final text = j['text'] == null ? null : '${j['text']}'.trim();
      if ((action == VoiceAction.askAi) && (text == null || text.isEmpty)) return null;
      return VoiceIntent(action, target: action == VoiceAction.open ? target : null, text: (text == null || text.isEmpty) ? null : text);
    } catch (_) {
      return null;
    }
  }

  Future<VoiceIntent?> interpret(String phrase) async {
    try {
      final r = await service.ask(
        task: 'voice',
        systemPrompt: _system,
        contextBlock: '',
        history: [(role: 'user', text: phrase)],
        json: true,
        rotateKeys: true,
      );
      return parseReply(r.text);
    } catch (_) {
      return null;
    }
  }
}
