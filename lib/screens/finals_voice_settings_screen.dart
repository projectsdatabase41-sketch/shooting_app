import 'package:flutter/material.dart';

import '../finals/voice_packs.dart';
import '../i18n/i18n.dart';
import '../services/ai_settings.dart';
import '../services/local_db_service.dart';
import '../widgets/glass_pill.dart';
import 'finals_voice_clips_screen.dart';

/// Отдельный экран «Голос ИИ для финалов» (открывается из финалов); те же настройки лежат в
/// настройках ИИ, если добавлен свой ключ.
class FinalsVoiceSettingsScreen extends StatelessWidget {
  final LocalDbService db;
  const FinalsVoiceSettingsScreen({super.key, required this.db});

  @override
  Widget build(BuildContext context) => Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
            title: Text(tr('Голос ИИ для финалов'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 32),
          children: [FinalsVoicePanel(db: db, standalone: true)],
        ),
      );
}

/// Настройки озвучки финалов моделью ИИ. По умолчанию озвучка прежняя (голос телефона). Когда в
/// настройках ИИ добавлен свой ключ, можно включить озвучку моделью: используются ключ и адрес из
/// настроек ИИ, а здесь выбираются модель озвучки и голос.
class FinalsVoicePanel extends StatefulWidget {
  final LocalDbService db;

  /// Отдельный экран (из финалов): без своего ключа ИИ показывается только подсказка.
  /// Внутри настроек ИИ без ключа панель скрыта целиком (ключ вводится рядом).
  final bool standalone;
  const FinalsVoicePanel({super.key, required this.db, this.standalone = false});

  @override
  State<FinalsVoicePanel> createState() => _FinalsVoicePanelState();
}

class _FinalsVoicePanelState extends State<FinalsVoicePanel> {
  late final VoiceConfig _c = VoicePacks.config(widget.db);
  late final _model = TextEditingController(text: _c.model);
  late final _voice = TextEditingController(text: _c.voice);
  late final _url = TextEditingController(text: VoicePacks.urlOverride(widget.db));
  late bool _on = VoicePacks.enabled(widget.db);
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_model, _voice, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() => VoicePacks.saveSettings(widget.db, model: _model.text, voice: _voice.text, urlOverride: _url.text, enabled: _on);

  Future<void> _prepare() async {
    _save();
    final cfg = VoicePacks.config(widget.db);
    if (!cfg.usable) {
      setState(() => _message = tr('Нужен свой ключ ИИ (настройки ИИ → «Свой ключ») и включённый переключатель'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final made = await VoicePacks.ensureAll(widget.db);
    final st = VoicePacks.status.value;
    if (mounted) {
      setState(() {
        _busy = false;
        _message = st?.error != null ? st!.error : (made == 0 ? tr('Все записи уже готовы') : tr('Готово: создано записей — {n}', {'n': made}));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = AiSettings(widget.db).hasOwnKey;
    // Настройки озвучки видны только со своим ключом ИИ.
    if (!hasKey) {
      return widget.standalone
          ? Text(tr('Добавьте свой ключ в настройках ИИ ассистента — тогда здесь появятся настройки озвучки.'), style: theme.textTheme.bodyMedium)
          : const SizedBox.shrink();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        tr('Сейчас диктор говорит голосом телефона. Со своим ключом ИИ можно включить озвучку моделью: записи (команды, числа и фразы с именами, своим и ботов) создаются заранее, в финале только проигрываются. Нет записи — говорит голос телефона.'),
        style: theme.textTheme.bodySmall,
      ),
      if (!hasKey)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(tr('Добавьте свой ключ в настройках ИИ ассистента — тогда здесь появятся настройки озвучки.'), style: TextStyle(color: theme.colorScheme.error)),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Озвучка моделью ИИ')),
        subtitle: Text(tr('Используется ваш ключ и адрес из настроек ИИ')),
        value: _on && hasKey,
        onChanged: hasKey ? (v) => setState(() => _on = v) : null,
      ),
      Row(children: [
        Expanded(child: TextField(controller: _model, decoration: InputDecoration(labelText: tr('Модель озвучки'), helperText: 'tts-1'))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: _voice, decoration: InputDecoration(labelText: tr('Голос'), helperText: 'alloy'))),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: _url,
        decoration: InputDecoration(
          labelText: tr('Свой адрес озвучки (необязательно)'),
          helperText: tr('Пусто — адрес из настроек ИИ + /audio/speech'),
        ),
        keyboardType: TextInputType.url,
      ),
      const SizedBox(height: 12),
      ValueListenableBuilder<({int done, int total, String? error})?>(
        valueListenable: VoicePacks.status,
        builder: (_, st, __) => st == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, value: st.total == 0 ? null : st.done / st.total)),
                  const SizedBox(width: 8),
                  Text('${st.total == 0 ? 0 : (st.done * 100 / st.total).round()}%  (${st.done}/${st.total})', style: theme.textTheme.bodySmall),
                ]),
              ),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _busy || !hasKey ? null : _prepare,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.record_voice_over_outlined),
          label: Text(tr('Подготовить записи')),
        ),
        OutlinedButton.icon(
          onPressed: !hasKey ? null : () {
            _save();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => FinalsVoiceClipsScreen(db: widget.db)));
          },
          icon: const Icon(Icons.list_alt_outlined),
          label: Text(tr('Записи по одной')),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  _save();
                  await VoicePacks.clearAll();
                  if (mounted) setState(() => _message = tr('Записи удалены'));
                },
          icon: const Icon(Icons.delete_outline),
          label: Text(tr('Удалить записи')),
        ),
      ]),
      if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
    ]);
  }
}
