import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/target_color_scheme.dart';
import '../state/personalization_view_model.dart';

/// Диалог выбора цвета (часть A.3.1 логики-спека). Два таба: "Палитра"
/// (круг+слайдер яркости — упрощено до HSV picker) и "HEX" (ручной ввод +
/// read-only RGB/HSL + чипы прозрачности для alpha-capable ключей).
/// "Недавние цвета" и переключатель "Автоконтраст текста" для ключей
/// цветов пробоин.
class ColorPickerDialog extends StatefulWidget {
  final String colorKey;
  final String title;

  const ColorPickerDialog({super.key, required this.colorKey, required this.title});

  static Future<void> show(BuildContext context, String colorKey, String title) {
    return showDialog(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<PersonalizationViewModel>(),
        child: ColorPickerDialog(colorKey: colorKey, title: title),
      ),
    );
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> with SingleTickerProviderStateMixin {
  late TabController _tab;
  late TextEditingController _hexController;
  late Color _color;

  bool get _alphaCapable => TargetColorScheme.alphaCapableKeys.contains(widget.colorKey);
  bool get _autoContrastRelevant => TargetColorScheme.autoContrastRelevantKeys.contains(widget.colorKey);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    final vm = context.read<PersonalizationViewModel>();
    _color = vm.scheme[widget.colorKey];
    _hexController = TextEditingController(text: TargetColorScheme.colorToHex(_color));
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
      _hexController.text = TargetColorScheme.colorToHex(c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(controller: _tab, tabs: const [Tab(text: 'Палитра'), Tab(text: 'HEX')]),
            SizedBox(
              height: 260,
              child: TabBarView(
                controller: _tab,
                children: [_buildPaletteTab(), _buildHexTab()],
              ),
            ),
            if (_alphaCapable) _buildAlphaChips(),
            if (vm.recentColors.isNotEmpty) _buildRecentColors(vm),
            if (_autoContrastRelevant) _buildAutoContrastToggle(vm),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            vm.setColor(widget.colorKey, _color);
            Navigator.of(context).pop();
          },
          child: const Text('Применить'),
        ),
      ],
    );
  }

  Widget _buildPaletteTab() {
    // Упрощённый цветовой круг + слайдер яркости через HSV-компоненты.
    final hsv = HSVColor.fromColor(_color);
    return Column(
      children: [
        Expanded(
          child: GridView.count(
            crossAxisCount: 8,
            children: List.generate(64, (i) {
              final hue = (i % 8) * 45.0;
              final sat = 0.3 + (i ~/ 8) * 0.1;
              final c = HSVColor.fromAHSV(1, hue, sat.clamp(0, 1), hsv.value).toColor();
              return GestureDetector(
                onTap: () => _apply(c),
                child: Container(margin: const EdgeInsets.all(2), color: c),
              );
            }),
          ),
        ),
        Row(
          children: [
            const Text('Яркость'),
            Expanded(
              child: Slider(
                value: hsv.value,
                onChanged: (v) => _apply(hsv.withValue(v).toColor()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHexTab() {
    final hsl = HSLColor.fromColor(_color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _hexController,
          decoration: const InputDecoration(labelText: 'HEX (#RRGGBB или #AARRGGBB)'),
          onChanged: (value) {
            if (TargetColorScheme.isValidHex(value)) {
              setState(() => _color = TargetColorScheme.hexToColor(value));
            }
          },
        ),
        if (!TargetColorScheme.isValidHex(_hexController.text))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Некорректный HEX',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
          ),
        const SizedBox(height: 12),
        // Две строки, каждая на всю ширину, с переносом.
        //
        // Раньше RGB и HSL стояли в один ряд и на узком экране
        // наезжали друг на друга: «HSL: 205°, 24%…» упиралось в
        // соседнюю колонку и обрезалось на полуслове.
        Text(
          'RGB  ${(_color.r * 255).round()} · ${(_color.g * 255).round()} · ${(_color.b * 255).round()}',
          style: const TextStyle(fontSize: 12),
          softWrap: true,
        ),
        const SizedBox(height: 4),
        Text(
          'HSL  ${hsl.hue.toStringAsFixed(0)}° · '
          '${(hsl.saturation * 100).toStringAsFixed(0)}% · '
          '${(hsl.lightness * 100).toStringAsFixed(0)}%',
          style: const TextStyle(fontSize: 12),
          softWrap: true,
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(height: 40, color: _color),
        ),
      ],
    );
  }

  Widget _buildAlphaChips() {
    const presets = [1.0, 0.8, 0.6, 0.4, 0.2];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        children: presets.map((a) {
          final selected = (_color.a - a).abs() < 0.02;
          return ChoiceChip(
            label: Text('${(a * 100).round()}%'),
            selected: selected,
            onSelected: (_) => _apply(_color.withAlpha((a * 255).round())),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRecentColors(PersonalizationViewModel vm) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Text('Недавние: ', style: TextStyle(fontSize: 12)),
          ...vm.recentColors.map((c) => GestureDetector(
                onTap: () => _apply(c),
                child: Container(
                  width: 24,
                  height: 24,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: c,
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                    shape: BoxShape.circle,
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildAutoContrastToggle(PersonalizationViewModel vm) {
    return SwitchListTile(
      dense: true,
      title: const Text('Автоконтраст текста', style: TextStyle(fontSize: 13)),
      subtitle: const Text('Текст внутри пробоин будет выбран автоматически для максимальной читаемости',
          style: TextStyle(fontSize: 11)),
      value: vm.scheme.shotNumberTextAuto,
      onChanged: vm.setShotNumberTextAuto,
    );
  }
}
