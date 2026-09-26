import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import '../models/app_color_presets.dart';
import '../models/color_presets.dart';
import '../models/target_color_scheme.dart';
import '../models/target_face.dart';
import '../painters/target_painter.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import '../widgets/color_picker_dialog.dart';
import '../i18n/i18n.dart';

/// Переключатель светлой/тёмной темы интерфейса.
///
/// Значение живёт в `PersonalizationViewModel` (та же key-value таблица
/// `color_prefs`), поэтому переживает перезапуск. "Система" — значение
/// по умолчанию: приложение следует настройке ОС.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              icon: const Icon(Icons.brightness_auto_outlined),
              label: Text(tr('Система')),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: const Icon(Icons.light_mode_outlined),
              label: Text(tr('Светлая')),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: const Icon(Icons.dark_mode_outlined),
              label: Text(tr('Тёмная')),
            ),
          ],
          selected: {vm.themeMode},
          showSelectedIcon: false,
          onSelectionChanged: (set) => vm.setThemeMode(set.first),
        ),
      ),
    );
  }
}

/// Экран "Персонализация цвета" (часть A.3 логики-спека, задача 2.3/2.5
/// dev-task-spec.md). Два таба: "Элементы" (список по 5 секциям) и
/// "Пресеты" (сетка карточек). Раскладка переключается 1/2 колонки по
/// ширине окна — актуально и для Windows (ресайз окна).
class ColorPersonalizationScreen extends StatefulWidget {
  const ColorPersonalizationScreen({super.key});

  @override
  State<ColorPersonalizationScreen> createState() => _ColorPersonalizationScreenState();
}

class _ColorPersonalizationScreenState extends State<ColorPersonalizationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _showPreviewOnNarrow = false;

  static const _sections = <String, List<String>>{
    /*tr*/ 'МИШЕНЬ': ['target_paper', 'target_bullseye', 'ring_lines', 'ring_labels_on_paper', 'ring_labels_on_bullseye'],
    /*tr*/ 'ПРОБОИНЫ': ['shot_selected', 'shot_current_series', 'shot_past_series', 'shot_number_text'],
    /*tr*/ 'ПРАВКА': ['compass_ring', 'edit_result_badge', 'edit_angle_badge'],
    /*tr*/ 'ИНТЕРФЕЙС': ['bottom_panel_bg', 'bottom_panel_text'],
    /*tr*/ 'ПРОЧЕЕ': ['crosshair'],
  };

  static const _titles = <String, String>{
    'target_paper': /*tr*/ 'Фон мишени (бумага)',
    'target_bullseye': /*tr*/ 'Чёрное яблоко',
    'ring_lines': /*tr*/ 'Линии колец',
    'ring_labels_on_paper': /*tr*/ 'Цифры на бумаге',
    'ring_labels_on_bullseye': /*tr*/ 'Цифры на яблоке',
    'shot_selected': /*tr*/ 'Выбранный выстрел',
    'shot_current_series': /*tr*/ 'Выстрелы текущей серии',
    'shot_past_series': /*tr*/ 'Выстрелы прошлых серий',
    'shot_number_text': /*tr*/ 'Номер внутри пробоины',
    'compass_ring': /*tr*/ 'Компас (режим правки)',
    'edit_result_badge': /*tr*/ 'Индикатор результата',
    'edit_angle_badge': /*tr*/ 'Индикатор угла/часов',
    'bottom_panel_bg': /*tr*/ 'Фон панели правки',
    'bottom_panel_text': /*tr*/ 'Текст панели правки',
    'crosshair': /*tr*/ 'Перекрестие',
  };

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Цветовые настройки')),
        bottom: TabBar(controller: _tab, tabs: [Tab(text: tr('ЭЛЕМЕНТЫ')), Tab(text: tr('ПРЕСЕТЫ'))]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'export' ? _export(context) : _import(context),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'export', child: Text(tr('Экспорт'))),
              PopupMenuItem(value: 'import', child: Text(tr('Импорт'))),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 700;
          final list = TabBarView(
            controller: _tab,
            children: [_buildElementsTab(context, wide), _buildPresetsTab(context)],
          );
          if (wide) {
            return Row(
              children: [
                Expanded(flex: 3, child: list),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: _buildFullPreview(context)),
              ],
            );
          }
          return Stack(
            children: [
              list,
              if (_showPreviewOnNarrow)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Column(
                      children: [
                        Expanded(child: _buildFullPreview(context)),
                        SafeArea(
                          child: TextButton(
                            onPressed: () => setState(() => _showPreviewOnNarrow = false),
                            child: Text(tr('Скрыть мишень'), style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: Builder(builder: (context) {
        final wide = MediaQuery.of(context).size.width >= 700;
        if (wide) return const SizedBox.shrink();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.gps_fixed),
              label: Text(tr('Показать мишень')),
              onPressed: () => setState(() => _showPreviewOnNarrow = true),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildElementsTab(BuildContext context, bool wide) {
    final vm = context.watch<PersonalizationViewModel>();
    final brightness = Theme.of(context).brightness;
    return ListView(
      children: [
        if (!wide) SizedBox(height: 160, child: _buildMiniPreview(context)),
        // Тема интерфейса (светлая/тёмная/системная) переехала сюда из
        // общих настроек (решение пользователя, пункт 4 списка правок:
        // "оформление цветов" и "персонализация цвета мишени" — одно и
        // то же по смыслу место, а не два разных).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            tr('ТЕМА ИНТЕРФЕЙСА'),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
          ),
        ),
        const _ThemeModeSelector(),
        const SizedBox(height: 16),
        // Цвета ПРИЛОЖЕНИЯ (не мишени) — фон экранов, кнопки, текст на
        // кнопках (решение пользователя: "в настройках цвета мало").
        // Отдельная секция, не строка `_sections`/`TargetColorScheme`:
        // это не персонализация мишени, а оформление интерфейса вокруг
        // неё (см. комментарий в `AppTheme`).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            tr('ПРИЛОЖЕНИЕ'),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
          ),
        ),
        // Набор текущей темы: при «Системе» — той, что сейчас у телефона.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            brightness == Brightness.dark ? tr('Для тёмной темы') : tr('Для светлой темы'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const _AppColorPresetsRow(),
        _AppColorRow(
          title: tr('Фон приложения'),
          color: vm.appBackgroundFor(brightness),
          onChanged: (c) => vm.setAppBackgroundColor(c, brightness),
        ),
        _AppColorRow(
          title: tr('Кнопки'),
          color: vm.appButtonFor(brightness),
          onChanged: (c) => vm.setAppButtonColor(c, brightness),
        ),
        _AppColorRow(
          title: tr('Текст на кнопках'),
          color: vm.appButtonTextFor(brightness),
          onChanged: (c) => vm.setAppButtonTextColor(c, brightness),
        ),
        if (vm.hasCustomAppColors(brightness))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => vm.resetAppColors(brightness),
                child: Text(tr('Сбросить цвета приложения')),
              ),
            ),
          ),
        const SizedBox(height: 8),
        for (final section in _sections.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              tr(section.key),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
            ),
          ),
          for (final key in section.value) _ColorRow(colorKey: key, title: tr(_titles[key]!)),
        ],
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(
            onPressed: () => _confirmResetAll(context, vm),
            child: Text(tr('Сбросить все')),
          ),
        ),
      ],
    );
  }

  Widget _buildPresetsTab(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    final active = vm.activePreset;
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.all(12),
      childAspectRatio: 0.9,
      children: ColorPresets.all.map((preset) {
        final isActive = active?.name == preset.name;
        return GestureDetector(
          onTap: () => vm.applyPreset(preset),
          child: Card(
            shape: isActive
                ? RoundedRectangleBorder(side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2), borderRadius: BorderRadius.circular(8))
                : null,
            child: Column(
              // ВАЖНО: без stretch Column даёт Expanded(CustomPaint) только
              // тугую высоту, а ширину — свободную (0..ширина карточки);
              // CustomPaint без явного `size` по умолчанию Size.zero и
              // "схлопывается" по свободной оси в 0 — карточка была видна
              // пустой (только вертикальная линия перекрестия у левого
              // края и точка-яблоко нулевого радиуса). stretch делает обе
              // оси тугими.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: CustomPaint(
                    painter: TargetPainter(
                      face: TargetFace.rifle10m,
                      colors: preset.scheme,
                      visibleShots: const [],
                      selectedShot: null,
                      currentSeriesNo: 1,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isActive) const Icon(Icons.check, size: 16),
                      Text(preset.name),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMiniPreview(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    // SizedBox.expand — та же причина, что и в _buildFullPreview ниже:
    // CustomPaint без явного `size` схлопывается в 0 по любой свободной
    // оси констрейнтов, .expand принудительно занимает всё доступное
    // место по обеим осям.
    return SizedBox.expand(
      child: CustomPaint(
        painter: TargetPainter(
          face: TargetFace.rifle10m,
          colors: vm.scheme,
          visibleShots: const [],
          selectedShot: null,
          currentSeriesNo: 1,
        ),
      ),
    );
  }

  Widget _buildFullPreview(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      // См. комментарий в _buildPresetsTab: Row даёт Expanded(этой панели)
      // тугую ширину, но свободную высоту (нет stretch) — без
      // SizedBox.expand холст рисовался нулевой высоты (видна была только
      // горизонтальная линия перекрестия во всю ширину панели).
      child: SizedBox.expand(
        child: CustomPaint(
          painter: TargetPainter(
            face: TargetFace.rifle10m,
            colors: vm.scheme,
            visibleShots: const [],
            selectedShot: null,
            currentSeriesNo: 1,
          ),
        ),
      ),
    );
  }

  void _confirmResetAll(BuildContext context, PersonalizationViewModel vm) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Сбросить все цвета?')),
        content: Text(tr('Все настройки цвета будут удалены и восстановлены значения по умолчанию.')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () {
              vm.resetAll();
              Navigator.of(dialogContext).pop();
            },
            child: Text(tr('Сбросить всё')),
          ),
        ],
      ),
    );
  }

  void _export(BuildContext context) {
    final vm = context.read<PersonalizationViewModel>();
    final json = vm.exportJson();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Экспорт цветовой схемы')),
        content: SingleChildScrollView(child: SelectableText(json)),
        actions: [
          // Выделять пятнадцать строк JSON пальцем на телефоне —
          // мучение, ради которого экспорт и не открывали.
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr('Схема скопирована'))),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(tr('Копировать')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('Закрыть')),
          ),
        ],
      ),
    );
  }

  void _import(BuildContext context) {
    final vm = context.read<PersonalizationViewModel>();
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Импорт цветовой схемы')),
        content: TextField(
          controller: controller,
          maxLines: 10,
          decoration: InputDecoration(hintText: tr('Вставьте JSON…')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () {
              try {
                vm.importJson(controller.text);
                Navigator.of(dialogContext).pop();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('Файл повреждён — импорт отклонён целиком'))),
                );
              }
            },
            child: Text(tr('Импортировать')),
          ),
        ],
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  final String colorKey;
  final String title;

  const _ColorRow({required this.colorKey, required this.title});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    final color = vm.scheme[colorKey];
    final isDefault = vm.scheme.isDefault(colorKey);

    return ListTile(
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      title: Text(title),
      // HEX-кода под названием больше нет: в списке из пятнадцати
      // компонентов он превращал экран в столбец «#37474F», по которому
      // ничего не найти. Код виден там, где он нужен, — во вкладке HEX
      // самой пипетки.
      trailing: IconButton(
        // Три состояния (A.3): по умолчанию — приглушена; изменено — заметна.
        icon: Icon(
          Icons.replay,
          color: isDefault
              ? Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.35)
              : Theme.of(context).colorScheme.primary,
        ),
        onPressed: isDefault
            ? null
            : () => _confirmReset(context, vm),
      ),
      onTap: () => ColorPickerDialog.showForTargetKey(context, colorKey, title),
    );
  }

  void _confirmReset(BuildContext context, PersonalizationViewModel vm) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Сбросить к умолчанию?')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () {
              vm.resetKey(colorKey);
              Navigator.of(dialogContext).pop();
            },
            child: Text(tr('Сбросить')),
          ),
        ],
      ),
    );
  }
}

/// Строка цвета ПРИЛОЖЕНИЯ (фон/кнопки/текст кнопок) — тот же вид, что
/// `_ColorRow`, но без привязки к `TargetColorScheme`: `color == null`
/// значит "цвет темы по умолчанию", а не конкретный HEX.
class _AppColorRow extends StatelessWidget {
  final String title;
  final Color? color;
  final ValueChanged<Color?> onChanged;

  const _AppColorRow({required this.title, required this.color, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = color ?? theme.colorScheme.surfaceContainerHigh;

    return ListTile(
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: shown,
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      title: Text(title),
      subtitle: color == null ? Text(tr('По умолчанию')) : null,
      trailing: IconButton(
        icon: Icon(
          Icons.replay,
          color: color == null
              ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35)
              : theme.colorScheme.primary,
        ),
        onPressed: color == null ? null : () => onChanged(null),
      ),
      onTap: () => ColorPickerDialog.showForColor(
        context,
        title: title,
        color: shown,
        onApply: onChanged,
      ),
    );
  }
}

/// Полоса готовых сочетаний (фон + кнопки + текст кнопок разом) —
/// "пресеты для меню" (решение пользователя), горизontal-скролл вместо
/// отдельной вкладки: их всего несколько штук, вкладка ради этого
/// избыточна (в отличие от пресетов мишени, которых много и у каждого
/// свой предпросмотр рисунком).
class _AppColorPresetsRow extends StatelessWidget {
  const _AppColorPresetsRow();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    // Только пресеты текущей темы — тёмных на светлой нет и наоборот.
    final presets = [...appColorPresets, ...vm.customPresets].where((p) => p.dark == dark).toList();
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: presets.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          if (i == presets.length) {
            return Tooltip(
              message: tr('Создать пресет'),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => ChangeNotifierProvider.value(
                    value: vm,
                    child: _CreatePresetSheet(brightness: brightness),
                  ),
                ),
                child: Container(
                  width: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [const Icon(Icons.add), const SizedBox(height: 4), Text(tr('Создать'), style: const TextStyle(fontSize: 10))],
                  ),
                ),
              ),
            );
          }
          final preset = presets[i];
          final active = vm.appBackgroundFor(brightness) == preset.background &&
              vm.appButtonFor(brightness) == preset.button &&
              vm.appButtonTextFor(brightness) == preset.buttonText;
          return GestureDetector(
            onTap: () => vm.applyAppColorPreset(preset),
            onLongPress: preset.custom
                ? () async {
                    final del = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(tr('Удалить пресет «{label}»?', {'label': preset.label})),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Отмена'))),
                          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Удалить'))),
                        ],
                      ),
                    );
                    if (del == true) vm.deleteCustomPreset(preset);
                  }
                : null,
            child: _PresetSwatch(preset: preset, active: active),
          );
        },
      ),
    );
  }
}

class _PresetSwatch extends StatelessWidget {
  final AppColorPreset preset;
  final bool active;
  const _PresetSwatch({required this.preset, this.active = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      decoration: BoxDecoration(
        color: preset.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
          width: active ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 18,
            decoration: BoxDecoration(color: preset.button, borderRadius: BorderRadius.circular(4)),
            alignment: Alignment.center,
            child: Container(width: 14, height: 3, color: preset.buttonText),
          ),
          const SizedBox(height: 6),
          Text(
            tr(preset.label),
            style: TextStyle(fontSize: 10, color: preset.background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white70),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// «Создать пресет»: сохранить текущие цвета темы или описать словами — ИИ
/// подберёт фон, кнопки и текст (с проверкой читаемости).
class _CreatePresetSheet extends StatefulWidget {
  final Brightness brightness;
  const _CreatePresetSheet({required this.brightness});

  @override
  State<_CreatePresetSheet> createState() => _CreatePresetSheetState();
}

class _CreatePresetSheetState extends State<_CreatePresetSheet> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  AppColorPreset? _draft;
  bool _busy = false;
  String? _error;

  bool get _dark => widget.brightness == Brightness.dark;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _fromCurrent() {
    final vm = context.read<PersonalizationViewModel>();
    final b = widget.brightness;
    final theme = Theme.of(context);
    setState(() => _draft = AppColorPreset(
          label: _name.text.trim().isEmpty ? tr('Мой') : _name.text.trim(),
          background: vm.appBackgroundFor(b) ?? theme.scaffoldBackgroundColor,
          button: vm.appButtonFor(b) ?? theme.colorScheme.primary,
          buttonText: vm.appButtonTextFor(b) ?? theme.colorScheme.onPrimary,
          dark: _dark,
          custom: true,
        ));
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  Future<void> _withAi() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = context.read<AppDataStore>().db;
      final reply = await AiService(AiSettings(db)).ask(
        task: 'app_preset',
        json: true,
        systemPrompt: 'Ты подбираешь цвета интерфейса приложения для ${_dark ? 'ТЁМНОЙ' : 'СВЕТЛОЙ'} темы по описанию. '
            'Ответь ТОЛЬКО JSON: {"label":"название 1-2 слова","background":"#RRGGBB","button":"#RRGGBB","buttonText":"#RRGGBB"}. '
            'Фон ${_dark ? 'тёмный (яркость ниже 25%)' : 'светлый (яркость выше 85%)'}, текст на кнопке хорошо читается на кнопке, '
            'кнопка заметна на фоне. Название — на языке описания.',
        contextBlock: '',
        history: [(role: 'user', text: text)],
      );
      var raw = reply.text.trim();
      final fence = RegExp(r'```\w*\s*([\s\S]*?)```').firstMatch(raw);
      if (fence != null) raw = fence.group(1)!.trim();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final bg = TargetColorScheme.hexToColor('${j['background']}');
      final button = TargetColorScheme.hexToColor('${j['button']}');
      var buttonText = TargetColorScheme.hexToColor('${j['buttonText']}');
      // Страховка от нечитаемого сочетания и «чужой» темы.
      if (_contrast(button, buttonText) < 3) {
        buttonText = button.computeLuminance() > 0.5 ? Colors.black : Colors.white;
      }
      if ((bg.computeLuminance() > 0.5) == _dark) {
        throw Exception(tr('ИИ подобрал фон не для той темы — попробуйте переформулировать'));
      }
      setState(() => _draft = AppColorPreset(
            label: '${j['label'] ?? 'ИИ'}'.trim(),
            background: bg,
            button: button,
            buttonText: buttonText,
            dark: _dark,
            custom: true,
          ));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final d = _draft;
    if (d == null) return;
    final name = _name.text.trim();
    final preset = AppColorPreset(
      label: name.isEmpty ? d.label : name,
      background: d.background,
      button: d.button,
      buttonText: d.buttonText,
      dark: d.dark,
      custom: true,
    );
    final vm = context.read<PersonalizationViewModel>();
    vm.addCustomPreset(preset);
    vm.applyAppColorPreset(preset);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Новый пресет — {p} тема', {'p': _dark ? tr('тёмная') : tr('светлая')}), style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: InputDecoration(labelText: tr('Название (необязательно)'))),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _fromCurrent,
            icon: const Icon(Icons.save_outlined),
            label: Text(tr('Из текущих цветов')),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _prompt,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: tr('Или опишите — подберёт ИИ'),
              hintText: tr('например: «спокойный морской, акцент бирюзовый»'),
              suffixIcon: _busy
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(icon: const Icon(Icons.auto_awesome_outlined), onPressed: _withAi),
            ),
            onSubmitted: (_) => _withAi(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_draft != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                _PresetSwatch(preset: _draft!),
                const SizedBox(width: 12),
                Expanded(child: Text(tr('Так будет выглядеть «{p}»', {'p': _name.text.trim().isEmpty ? _draft!.label : _name.text.trim()}))),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _save, child: Text(tr('Сохранить и применить'))),
          ],
        ],
      ),
    );
  }
}
