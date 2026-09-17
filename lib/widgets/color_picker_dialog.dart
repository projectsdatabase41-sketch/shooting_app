import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import '../models/target_color_scheme.dart';
import '../state/personalization_view_model.dart';

/// Диалог выбора цвета (часть A.3.1 логики-спека). Два таба: "Палитра"
/// (круг+слайдер яркости — упрощено до HSV picker) и "HEX" (ручной ввод +
/// read-only RGB/HSL + чипы прозрачности для alpha-capable ключей).
/// "Недавние цвета" и переключатель "Автоконтраст текста" — только для
/// ключей цветов пробоин (`showForTargetKey`).
///
/// Сам диалог не завязан на `TargetColorScheme` — принимает готовый цвет
/// и колбэк (`ColorPickerDialog._`), а `showForTargetKey`/`showForColor`
/// — два способа его открыть: под цвет мишени (ключ в `PersonalizationViewModel.scheme`)
/// и под произвольный цвет приложения (фон, кнопки — не часть
/// `TargetColorScheme`, см. комментарий там же о том, почему их нельзя
/// смешивать).
class ColorPickerDialog extends StatefulWidget {
  final String title;
  final Color initialColor;
  final ValueChanged<Color> onApply;
  final List<Color> recentColors;
  final bool showAutoContrast;
  final bool autoContrastValue;
  final ValueChanged<bool>? onAutoContrastChanged;

  const ColorPickerDialog._({
    required this.title,
    required this.initialColor,
    required this.onApply,
    this.recentColors = const [],
    this.showAutoContrast = false,
    this.autoContrastValue = false,
    this.onAutoContrastChanged,
  });

  /// Цвет из `TargetColorScheme` (мишень, пробоины, панель правки).
  static Future<void> showForTargetKey(BuildContext context, String colorKey, String title) {
    final vm = context.read<PersonalizationViewModel>();
    return showDialog(
      context: context,
      builder: (_) => AnimatedBuilder(
        animation: vm,
        builder: (context, _) => ColorPickerDialog._(
          title: title,
          initialColor: vm.scheme[colorKey],
          onApply: (c) => vm.setColor(colorKey, c),
          recentColors: vm.recentColors,
          showAutoContrast: TargetColorScheme.autoContrastRelevantKeys.contains(colorKey),
          autoContrastValue: vm.scheme.shotNumberTextAuto,
          onAutoContrastChanged: vm.setShotNumberTextAuto,
        ),
      ),
    );
  }

  /// Произвольный цвет приложения (фон, кнопки, текст кнопок) — готовый
  /// цвет и колбэк применения, без привязки к `TargetColorScheme`.
  static Future<void> showForColor(
    BuildContext context, {
    required String title,
    required Color color,
    required ValueChanged<Color> onApply,
  }) {
    return showDialog(
      context: context,
      builder: (_) => ColorPickerDialog._(title: title, initialColor: color, onApply: onApply),
    );
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> with SingleTickerProviderStateMixin {
  late TabController _tab;
  late TextEditingController _hexController;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _color = widget.initialColor;
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
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(controller: _tab, tabs: const [Tab(text: 'Палитра'), Tab(text: 'HEX')]),
            // ClipRect — у ColorPicker (flutter_colorpicker) внутренний
            // Stack иногда рисует чуть шире отведённой ему полосы
            // TabBarView и "протекает" на соседнюю вкладку без обрезки
            // (сама TabBarView клипует по страницам, а не по контенту
            // internal Stack'а пакета). Без ClipRect на HEX-вкладке было
            // видно обрывок колеса и слайдера с "Палитры".
            SizedBox(
              height: 340,
              child: ClipRect(
                child: TabBarView(
                  controller: _tab,
                  children: [_buildPaletteTab(), _buildHexTab()],
                ),
              ),
            ),
            if (widget.recentColors.isNotEmpty) _buildRecentColors(),
            if (widget.showAutoContrast) _buildAutoContrastToggle(),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            widget.onApply(_color);
            Navigator.of(context).pop();
          },
          child: const Text('Применить'),
        ),
      ],
    );
  }

  Widget _buildPaletteTab() {
    // БЕЗ ScrollView вокруг: он даёт дочернему виджету бесконечную высоту
    // по оси прокрутки, а ColorPicker считает размер колеса как долю
    // (pickerAreaHeightPercent) от полученной высоты — на бесконечности
    // колесо рисуется схлопнутым в полоску и вылезает за рамки диалога.
    // Здесь высота и так конечная — задана снаружи через SizedBox.
    return ColorPicker(
      pickerColor: _color,
      onColorChanged: _apply,
      paletteType: PaletteType.hueWheel,
      enableAlpha: false,
      labelTypes: const [],
      colorPickerWidth: 280,
      pickerAreaHeightPercent: 0.7,
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

  Widget _buildRecentColors() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Text('Недавние: ', style: TextStyle(fontSize: 12)),
          ...widget.recentColors.map((c) => GestureDetector(
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

  Widget _buildAutoContrastToggle() {
    return SwitchListTile(
      dense: true,
      title: const Text('Автоконтраст текста', style: TextStyle(fontSize: 13)),
      subtitle: const Text('Текст внутри пробоин будет выбран автоматически для максимальной читаемости',
          style: TextStyle(fontSize: 11)),
      value: widget.autoContrastValue,
      onChanged: widget.onAutoContrastChanged,
    );
  }
}
