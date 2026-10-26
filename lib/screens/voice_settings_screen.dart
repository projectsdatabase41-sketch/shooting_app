import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../voice/voice_control.dart';
import '../widgets/glass_pill.dart';

/// Настройки голосового управления.
class VoiceSettingsScreen extends StatefulWidget {
  final LocalDbService db;
  const VoiceSettingsScreen({super.key, required this.db});

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  late bool _ai = VoiceSettings.aiOn(widget.db);
  late final TextEditingController _model = TextEditingController(text: VoiceSettings.model(widget.db) == 'auto' ? '' : VoiceSettings.model(widget.db));

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Голосовое управление'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: VoiceSettings.enabled,
            builder: (_, on, __) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Голосовое управление')),
              subtitle: Text(tr('Кнопка микрофона поверх приложения. Речь распознаёт сам телефон — бесплатно, без отправки в ИИ.')),
              value: on,
              onChanged: (v) => VoiceSettings.setEnabled(widget.db, v),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('Что можно сказать'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            tr('«Открой настройки / финалы / мессенджер / статистику», «Начать тренировку», «Пауза», «Продолжить», «Завершить тренировку», «Отмени последний выстрел», «Режим концентрации», «Заметка …» (текст сохранится как заметка к выстрелу), «Готов» (в финале), «Назад».'),
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('ИИ-помощник для сложных фраз')),
            subtitle: Text(tr('Если команда не разобрана по правилам, отдельная модель ИИ выбирает действие из списка. Она ничего не пишет от себя.')),
            value: _ai,
            onChanged: (v) {
              setState(() => _ai = v);
              VoiceSettings.setAiOn(widget.db, v);
            },
          ),
          if (_ai)
            TextField(
              controller: _model,
              decoration: InputDecoration(labelText: tr('Модель помощника (пусто — автоматически)'), hintText: 'auto'),
              onChanged: (v) => VoiceSettings.setModel(widget.db, v),
            ),
        ],
      ),
    );
  }
}
