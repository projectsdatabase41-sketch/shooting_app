import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/target_color_scheme.dart' show TargetColorScheme;
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/chat_preferences.dart';
import '../services/local_db_service.dart';

/// Настройки чата (пункты 4, 6, 7 списка правок) — открывается из левой
/// панели чата, а не из общих настроек приложения: это оформление
/// именно переписки, а не всего приложения.
class ChatAppearanceScreen extends StatefulWidget {
  final ChatPreferences prefs;
  final LocalDbService db;
  const ChatAppearanceScreen({super.key, required this.prefs, required this.db});

  @override
  State<ChatAppearanceScreen> createState() => _ChatAppearanceScreenState();
}

class _ChatAppearanceScreenState extends State<ChatAppearanceScreen> {
  Future<void> _pickColor(String title, Color current, ValueChanged<Color> onPicked) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _ColorPickerDialog(title: title, initial: current),
    );
    if (picked != null) setState(() => onPicked(picked));
  }

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder, а не голое чтение widget.prefs — настройки могут
    // поменяться не только с этого экрана (например, из "Настроить с
    // ИИ", отдельный лист), и без подписки на notifyListeners() экран
    // не обновился бы сам.
    return AnimatedBuilder(animation: widget.prefs, builder: (context, _) => _buildScaffold(context));
  }

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = widget.prefs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Персонализация'),
        actions: [
          IconButton(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => _AiThemeAssistantSheet(prefs: prefs, db: widget.db),
            ),
            icon: const Icon(Icons.auto_awesome_outlined),
            tooltip: 'Настроить с ИИ',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _preview(),
          const SizedBox(height: 24),
          Text('Оформление сообщений', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Готовые сочетания цветов — заполняют поля ниже сразу.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [for (final preset in ChatPreferences.presets) _presetCard(preset)],
          ),
          const SizedBox(height: 20),
          Text('Цвета вручную', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _colorTile('Фон моего сообщения', prefs.mineBubbleColor, (c) => prefs.mineBubbleColor = c),
          _colorTile('Фон сообщений собеседника', prefs.otherBubbleColor, (c) => prefs.otherBubbleColor = c),
          _colorTile('Мой текст', prefs.mineTextColor, (c) => prefs.mineTextColor = c),
          _colorTile('Текст собеседника', prefs.otherTextColor, (c) => prefs.otherTextColor = c),
          const SizedBox(height: 20),
          Text('Тень', style: theme.textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Тень под сообщениями'),
            value: prefs.shadowEnabled,
            onChanged: (v) => setState(() => prefs.shadowEnabled = v),
          ),
          if (prefs.shadowEnabled)
            Row(
              children: [
                const Text('Слабее'),
                Expanded(
                  child: Slider(
                    value: prefs.shadowIntensity,
                    onChanged: (v) => setState(() => prefs.shadowIntensity = v),
                  ),
                ),
                const Text('Сильнее'),
              ],
            ),
          const SizedBox(height: 20),
          Text('Текст и форма', style: theme.textTheme.titleMedium),
          Row(
            children: [
              const SizedBox(width: 110, child: Text('Размер текста')),
              Expanded(
                child: Slider(
                  value: prefs.fontScale,
                  min: 0.85,
                  max: 1.3,
                  divisions: 9,
                  label: '${(prefs.fontScale * 100).round()}%',
                  onChanged: (v) => prefs.fontScale = v,
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 110, child: Text('Скругление')),
              Expanded(
                child: Slider(
                  value: prefs.bubbleRadius,
                  min: 4,
                  max: 28,
                  divisions: 12,
                  label: prefs.bubbleRadius.round().toString(),
                  onChanged: (v) => prefs.bubbleRadius = v,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Фон переписки', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _wallpaperTile('', 'Как в приложении', null),
              for (final e in ChatPreferences.chatWallpapers.entries)
                _wallpaperTile(
                  e.key,
                  e.value.$1,
                  BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: e.value.$2),
                  ),
                ),
              _wallpaperTile(
                prefs.wallpaper.startsWith('#') ? prefs.wallpaper : '#custom',
                'Свой цвет',
                prefs.wallpaper.startsWith('#') ? prefs.wallpaperDecoration : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Живой предпросмотр: пара сообщений на выбранном фоне.
  Widget _preview() {
    final prefs = widget.prefs;
    final theme = Theme.of(context);
    Widget bubble(String text, bool mine) {
      final base = mine ? prefs.mineBubbleColor : prefs.otherBubbleColor;
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(prefs.bubbleRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(base, Colors.white, 0.08)!, Color.lerp(base, Colors.black, 0.10)!],
            ),
            boxShadow: prefs.shadowEnabled
                ? [BoxShadow(color: Colors.black.withValues(alpha: prefs.shadowIntensity), blurRadius: 10, offset: const Offset(0, 4))]
                : null,
          ),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: mine ? prefs.mineTextColor : prefs.otherTextColor,
              fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * prefs.fontScale,
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: prefs.wallpaperDecoration ??
            BoxDecoration(color: theme.colorScheme.surfaceContainerLow, border: Border.all(color: theme.dividerColor)),
        child: Column(
          children: [
            bubble('Как прошла тренировка?', false),
            bubble('Отлично: 98 из 100, хват держал 👍', true),
          ],
        ),
      ),
    );
  }

  Widget _wallpaperTile(String id, String label, BoxDecoration? decoration) {
    final theme = Theme.of(context);
    final prefs = widget.prefs;
    final selected = id == '#custom' ? false : prefs.wallpaper == id;
    return GestureDetector(
      onTap: () async {
        if (id == '#custom' || id.startsWith('#')) {
          final current = prefs.wallpaper.startsWith('#')
              ? TargetColorScheme.hexToColor(prefs.wallpaper)
              : theme.colorScheme.surface;
          await _pickColor('Цвет фона', current, (c) {
            prefs.wallpaper = TargetColorScheme.colorToHex(c, withAlpha: false);
          });
        } else {
          prefs.wallpaper = id;
        }
      },
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: (decoration ?? BoxDecoration(color: theme.colorScheme.surface)).copyWith(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? theme.colorScheme.primary : theme.dividerColor,
                width: selected ? 3 : 1,
              ),
            ),
            child: id == '#custom' ? const Icon(Icons.colorize_outlined) : null,
          ),
          const SizedBox(height: 4),
          SizedBox(width: 72, child: Text(label, textAlign: TextAlign.center, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _colorTile(String title, Color color, ValueChanged<Color> onPicked) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(TargetColorScheme.colorToHex(color, withAlpha: false)),
      trailing: GestureDetector(
        onTap: () => _pickColor(title, color, onPicked),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
        ),
      ),
      onTap: () => _pickColor(title, color, onPicked),
    );
  }

  Widget _presetCard(ChatBubblePreset preset) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => widget.prefs.applyPreset(preset)),
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [_swatch(preset.mine), const SizedBox(width: 6), _swatch(preset.other)],
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

/// Компактный выбор цвета (палитра + HEX) — облегчённая копия
/// `ColorPickerDialog` из настроек мишени, без "недавних цветов" и
/// автоконтраста (там это завязано на `PersonalizationViewModel`,
/// цвета чата — независимая, отдельная настройка).
class _ColorPickerDialog extends StatefulWidget {
  final String title;
  final Color initial;
  const _ColorPickerDialog({required this.title, required this.initial});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> with SingleTickerProviderStateMixin {
  late TabController _tab;
  late TextEditingController _hexController;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _color = widget.initial;
    _hexController = TextEditingController(text: TargetColorScheme.colorToHex(_color, withAlpha: false));
  }

  @override
  void dispose() {
    _tab.dispose();
    _hexController.dispose();
    super.dispose();
  }

  void _apply(Color c) {
    setState(() {
      _color = c;
      _hexController.text = TargetColorScheme.colorToHex(c, withAlpha: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(controller: _tab, tabs: const [Tab(text: 'Палитра'), Tab(text: 'HEX')]),
            SizedBox(height: 220, child: TabBarView(controller: _tab, children: [_paletteTab(), _hexTab()])),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_color), child: const Text('Применить')),
      ],
    );
  }

  Widget _paletteTab() {
    final hsv = HSVColor.fromColor(_color);
    return Column(
      children: [
        Expanded(
          child: GridView.count(
            crossAxisCount: 8,
            children: List.generate(64, (i) {
              final hue = (i % 8) * 45.0;
              final sat = (0.3 + (i ~/ 8) * 0.1).clamp(0.0, 1.0);
              final c = HSVColor.fromAHSV(1, hue, sat, hsv.value).toColor();
              return GestureDetector(
                onTap: () => _apply(c),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: c, border: c == _color ? Border.all(color: Colors.white, width: 3) : null),
                ),
              );
            }),
          ),
        ),
        Row(
          children: [
            const Text('Яркость'),
            Expanded(child: Slider(value: hsv.value, onChanged: (v) => _apply(hsv.withValue(v).toColor()))),
          ],
        ),
      ],
    );
  }

  Widget _hexTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _hexController,
          decoration: const InputDecoration(labelText: 'HEX (#RRGGBB)'),
          onChanged: (value) {
            if (TargetColorScheme.isValidHex(value)) setState(() => _color = TargetColorScheme.hexToColor(value));
          },
        ),
        const SizedBox(height: 16),
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Container(height: 48, color: _color)),
      ],
    );
  }
}

/// "Чат с ИИ" для персонализации (решение пользователя) — только
/// цвета/тень, никакого доступа к сообщениям или их удалению: модель
/// физически не может тронуть переписку, у неё просто нет для этого
/// инструмента, только структурированный ответ ```chat_theme, который
/// разбирает и применяет этот экран.
class _AiThemeAssistantSheet extends StatefulWidget {
  final ChatPreferences prefs;
  final LocalDbService db;
  const _AiThemeAssistantSheet({required this.prefs, required this.db});

  @override
  State<_AiThemeAssistantSheet> createState() => _AiThemeAssistantSheetState();
}

class _AiThemeAssistantSheetState extends State<_AiThemeAssistantSheet> {
  final _input = TextEditingController();
  bool _busy = false;
  String? _reply;
  String? _error;

  Future<void> _ask() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _reply = null;
    });
    try {
      final ai = AiService(AiSettings(widget.db));
      final prefs = widget.prefs;
      final current = jsonEncode({
        'mine_bubble': TargetColorScheme.colorToHex(prefs.mineBubbleColor, withAlpha: false),
        'other_bubble': TargetColorScheme.colorToHex(prefs.otherBubbleColor, withAlpha: false),
        'mine_text': TargetColorScheme.colorToHex(prefs.mineTextColor, withAlpha: false),
        'other_text': TargetColorScheme.colorToHex(prefs.otherTextColor, withAlpha: false),
        'shadow_enabled': prefs.shadowEnabled,
        'shadow_intensity': prefs.shadowIntensity,
      });
      final reply = await ai.ask(
        task: 'chat_colors', accept: (t) => t.contains('```chat_theme'),
        systemPrompt: 'Ты помогаешь настроить ВНЕШНИЙ ВИД чата в приложении для стрелкового спорта: '
            'только цвет "своих" и "чужих" пузырей сообщений, цвет текста в них, и тень под ними '
            '(включена ли и насколько сильная, от 0 до 1). У тебя НЕТ доступа ни к чему другому — '
            'ни к самим сообщениям, ни к контактам, ни к их удалению, поэтому никогда не предлагай '
            'ничего, кроме этих настроек, и не делай вид, что сделал что-то ещё.\n'
            'Если пользователь просит что-то изменить — коротко подтверди своими словами (на том же языке, '
            'на котором он написал) что делаешь, и в конце ответа добавь блок ```chat_theme с ТОЛЬКО теми полями, которые нужно поменять '
            '(остальные не пиши): {"mine_bubble":"#RRGGBB","other_bubble":"#RRGGBB","mine_text":"#RRGGBB",'
            '"other_text":"#RRGGBB","shadow_enabled":true,"shadow_intensity":0.3}. '
            'Цвета — только HEX. Если просьба не про оформление — вежливо объясни, что умеешь только это.',
        contextBlock: 'ТЕКУЩИЕ НАСТРОЙКИ:\n$current',
        history: [(role: 'user', text: text)],
      );
      _applyThemeBlock(reply.text);
      if (mounted) setState(() => _reply = _stripThemeBlock(reply.text));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static final _blockRe = RegExp(r'```chat_theme\s*([\s\S]*?)```');

  String _stripThemeBlock(String text) => text.replaceAll(_blockRe, '').trim();

  void _applyThemeBlock(String text) {
    final match = _blockRe.firstMatch(text);
    if (match == null) return;
    try {
      final decoded = jsonDecode(match.group(1)!.trim());
      if (decoded is! Map) return;
      final prefs = widget.prefs;
      final mineBubble = decoded['mine_bubble'];
      if (mineBubble is String && TargetColorScheme.isValidHex(mineBubble)) {
        prefs.mineBubbleColor = TargetColorScheme.hexToColor(mineBubble);
      }
      final otherBubble = decoded['other_bubble'];
      if (otherBubble is String && TargetColorScheme.isValidHex(otherBubble)) {
        prefs.otherBubbleColor = TargetColorScheme.hexToColor(otherBubble);
      }
      final mineText = decoded['mine_text'];
      if (mineText is String && TargetColorScheme.isValidHex(mineText)) {
        prefs.mineTextColor = TargetColorScheme.hexToColor(mineText);
      }
      final otherText = decoded['other_text'];
      if (otherText is String && TargetColorScheme.isValidHex(otherText)) {
        prefs.otherTextColor = TargetColorScheme.hexToColor(otherText);
      }
      final shadowEnabled = decoded['shadow_enabled'];
      if (shadowEnabled is bool) prefs.shadowEnabled = shadowEnabled;
      final shadowIntensity = decoded['shadow_intensity'];
      if (shadowIntensity is num) prefs.shadowIntensity = shadowIntensity.toDouble();
    } catch (_) {
      // Модель ответила не тем форматом — просто ничего не применяем,
      // текстовый ответ пользователь всё равно увидит.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Настроить с ИИ', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Например: "сделай мои сообщения зелёными" или "убери тень".',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Что изменить?'),
            onSubmitted: (_) => _ask(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : _ask,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Отправить'),
            ),
          ),
          if (_reply != null) ...[
            const SizedBox(height: 12),
            Text(_reply!, style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
