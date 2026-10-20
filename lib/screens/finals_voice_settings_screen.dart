import 'package:flutter/material.dart';

import '../finals/voice_packs.dart';
import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../widgets/glass_pill.dart';

/// «Голос ИИ для финалов»: сервис озвучки, по которому приложение заранее готовит записи диктора
/// (команды, числа и фразы с именами — своим и ботов).
class FinalsVoiceSettingsScreen extends StatefulWidget {
  final LocalDbService db;
  const FinalsVoiceSettingsScreen({super.key, required this.db});

  @override
  State<FinalsVoiceSettingsScreen> createState() => _FinalsVoiceSettingsScreenState();
}

class _FinalsVoiceSettingsScreenState extends State<FinalsVoiceSettingsScreen> {
  late final VoiceConfig _c = VoicePacks.config(widget.db);
  late final _url = TextEditingController(text: _c.url);
  late final _key = TextEditingController(text: _c.key);
  late final _model = TextEditingController(text: _c.model);
  late final _voice = TextEditingController(text: _c.voice);
  late bool _on = _c.enabled;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _key, _model, _voice]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() => VoicePacks.saveConfig(widget.db, url: _url.text, key: _key.text, model: _model.text, voice: _voice.text, enabled: _on);

  Future<void> _prepare() async {
    _save();
    final cfg = VoicePacks.config(widget.db);
    if (!cfg.usable) {
      setState(() => _message = tr('Укажите адрес сервиса (https://…) и ключ, включите переключатель'));
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
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Голос ИИ для финалов'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 32),
        children: [
          Text(tr('Приложение заранее готовит записи диктора через сервис озвучки: когда вы сохраняете имя в анкете и когда меняете имя соперника. В финале записи только проигрываются, ожидания нет. Если записи нет — говорит голос телефона.')),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Использовать голос ИИ')),
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
          TextField(controller: _url, decoration: InputDecoration(labelText: tr('Адрес сервиса (…/v1/audio/speech)'), helperText: tr('Формат запроса, как у OpenAI; подходят совместимые сервисы'))),
          const SizedBox(height: 8),
          TextField(controller: _key, obscureText: true, decoration: InputDecoration(labelText: tr('Ключ'))),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _model, decoration: InputDecoration(labelText: tr('Модель')))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _voice, decoration: InputDecoration(labelText: tr('Голос')))),
          ]),
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
          FilledButton.icon(
            onPressed: _busy ? null : _prepare,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.record_voice_over_outlined),
            label: Text(tr('Подготовить записи')),
          ),
          if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    _save();
                    await VoicePacks.clearAll();
                    if (mounted) setState(() => _message = tr('Записи удалены'));
                  },
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Удалить все записи')),
          ),
        ],
      ),
    );
  }
}
