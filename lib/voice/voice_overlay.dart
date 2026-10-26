import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/glass_pill.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/feedback_service.dart';
import 'voice_actions.dart';
import 'voice_ai.dart';
import 'voice_control.dart';
import 'voice_grammar.dart';

/// Кнопка микрофона поверх приложения (если голосовое управление включено в настройках): нажали, сказали команду,
/// приложение разобрало её и выполнило на текущем экране. Кнопку можно перетащить.
class VoiceOverlay extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  const VoiceOverlay(
      {super.key, required this.navigatorKey, required this.child});

  @override
  State<VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends State<VoiceOverlay> {
  Offset _pos = const Offset(12, 220); // от правого нижнего угла

  /// Ответ с оценкой 👍/👎: оценка тихо уходит в отзывы (фраза, экран, как поняли, чем) — по ней правим разбор.
  void _rate(String phrase, String? mode, VoiceIntent intent, bool byAi,
      String result) {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    void vote(bool up) {
      ScaffoldMessenger.maybeOf(ctx)?.hideCurrentSnackBar();
      FeedbackService()
          .send(
              '[голос ${up ? '👍' : '👎'}] «$phrase» · экран: ${mode ?? 'общий'} · ${byAi ? 'ИИ' : 'правила'} · $intent · $result')
          .catchError((_) {});
    }

    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Row(children: [
          Expanded(child: Text(result)),
          IconButton(
              tooltip: tr('Верно'),
              icon: const Icon(Icons.thumb_up_outlined),
              onPressed: () => vote(true)),
          IconButton(
              tooltip: tr('Не то'),
              icon: const Icon(Icons.thumb_down_outlined),
              onPressed: () => vote(false)),
        ]),
      ));
  }

  void _say(String text) {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  Future<void> _tap() async {
    final vc = VoiceControl.instance;
    final phrase = await vc.listenOnce();
    if (phrase == null || phrase.trim().isEmpty) {
      _say(tr('Не расслышал — нажмите микрофон и повторите'));
      return;
    }
    final mode = vc.currentMode;
    var intent = VoiceGrammar.parse(phrase, mode: mode);
    var byAi = false;
    // Грамматика не поняла — ИИ-помощник (отдельная модель) выбирает действие из закрытого списка.
    final db = VoiceSettings.db;
    if (intent == null && db != null && VoiceSettings.aiOn(db)) {
      intent = await VoiceAi(AiService(AiSettings(db)))
          .interpret(phrase, mode: mode);
      byAi = intent != null;
    }
    if (intent == null) {
      FeedbackService()
          .send('[голос не понят] «$phrase» · экран: ${mode ?? 'общий'}')
          .catchError((_) {});
      _say(tr('Не понял команду: «{p}»', {'p': phrase}));
      return;
    }
    // Действия на любой странице (интернет, заметки, создание упражнения) выполняем здесь, остальные — экран.
    final ctx = widget.navigatorKey.currentContext;
    String result;
    switch (intent.action) {
      case VoiceAction.webSearch when ctx != null && db != null:
        result = await runWebSearch(ctx, db, intent.query);
      case VoiceAction.addDiaryNote when db != null:
        result = addDiaryNoteByVoice(db, intent.text);
      case VoiceAction.createExercise when ctx != null:
        result = await createExerciseByVoice(ctx, intent);
      default:
        result = await vc.execute(intent);
    }
    _rate(phrase, mode, intent, byAi, result);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: widget.child),
      ValueListenableBuilder<bool>(
        valueListenable: VoiceSettings.enabled,
        builder: (context, on, _) {
          if (!on) return const SizedBox.shrink();
          final size = MediaQuery.sizeOf(context);
          return Positioned(
            right: _pos.dx,
            bottom: _pos.dy,
            child: GestureDetector(
              onPanUpdate: (d) => setState(() {
                _pos = Offset(
                    (_pos.dx - d.delta.dx).clamp(0.0, size.width - 56),
                    (_pos.dy - d.delta.dy).clamp(0.0, size.height - 120));
              }),
              child: ValueListenableBuilder<bool>(
                valueListenable: VoiceControl.instance.listening,
                builder: (context, listening, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (listening)
                        ValueListenableBuilder<String>(
                          valueListenable: VoiceControl.instance.heard,
                          builder: (_, t, __) => Container(
                            constraints: const BoxConstraints(maxWidth: 240),
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(12)),
                            child: Text(t.isEmpty ? tr('Говорите…') : t,
                                style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                      // Круглая стеклянная кнопка, как у кнопки отзывов; при записи подсвечивается красным.
                  GlassCircleButton(
                    icon: BoldIcon(listening ? Icons.mic : Icons.mic_none),
                    color: listening ? Colors.redAccent.withValues(alpha: 0.55) : null,
                    onTap: _tap,
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
