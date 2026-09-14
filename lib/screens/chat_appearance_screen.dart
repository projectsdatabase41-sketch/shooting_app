import 'package:flutter/material.dart';

import '../services/chat_preferences.dart';

/// Настройки чата (пункты 4 и 6 списка правок) — открывается из левой
/// панели чата, а не из общих настроек приложения: это оформление
/// именно переписки, а не всего приложения.
class ChatAppearanceScreen extends StatefulWidget {
  final ChatPreferences prefs;
  const ChatAppearanceScreen({super.key, required this.prefs});

  @override
  State<ChatAppearanceScreen> createState() => _ChatAppearanceScreenState();
}

class _ChatAppearanceScreenState extends State<ChatAppearanceScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки чата')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Перевод сообщений', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Переводит входящие сообщения, если они не на языке системы устройства.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _translationTile(
            mode: ChatTranslationMode.off,
            title: 'Отключено',
            subtitle: 'Перевода нет вообще',
          ),
          _translationTile(
            mode: ChatTranslationMode.manual,
            title: 'По кнопке',
            subtitle: 'Кнопка "Перевести" при долгом нажатии на сообщение',
          ),
          _translationTile(
            mode: ChatTranslationMode.auto,
            title: 'Всегда автоматически',
            subtitle: 'Каждое сообщение не на языке системы переводится сразу',
          ),
          const SizedBox(height: 28),
          Text('Оформление сообщений', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Готовые сочетания цветов для пузырей переписки.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [for (final preset in ChatPreferences.presets) _presetCard(preset)],
          ),
        ],
      ),
    );
  }

  Widget _translationTile({required ChatTranslationMode mode, required String title, required String subtitle}) {
    return RadioListTile<ChatTranslationMode>(
      value: mode,
      groupValue: widget.prefs.translationMode,
      onChanged: (v) => setState(() => widget.prefs.translationMode = v!),
      title: Text(title),
      subtitle: Text(subtitle),
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _presetCard(ChatBubblePreset preset) {
    final selected = widget.prefs.bubblePreset.id == preset.id;
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => widget.prefs.bubblePreset = preset),
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? theme.colorScheme.primary : theme.dividerColor, width: selected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _swatch(preset.mine),
                const SizedBox(width: 6),
                _swatch(preset.other),
                const Spacer(),
                if (selected) Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            Text(preset.label, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _swatch(Color color) => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))],
        ),
      );
}
