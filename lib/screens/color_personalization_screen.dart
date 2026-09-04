import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import '../models/color_presets.dart';
import '../models/target_face.dart';
import '../painters/target_painter.dart';
import '../state/personalization_view_model.dart';
import '../widgets/color_picker_dialog.dart';

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
    'МИШЕНЬ': ['target_paper', 'target_bullseye', 'ring_lines', 'ring_labels_on_paper', 'ring_labels_on_bullseye'],
    'ПРОБОИНЫ': ['shot_selected', 'shot_current_series', 'shot_past_series', 'shot_number_text'],
    'ПРАВКА': ['compass_ring', 'edit_result_badge', 'edit_angle_badge'],
    'ИНТЕРФЕЙС': ['bottom_panel_bg', 'bottom_panel_text'],
    'ПРОЧЕЕ': ['crosshair'],
  };

  static const _titles = <String, String>{
    'target_paper': 'Фон мишени (бумага)',
    'target_bullseye': 'Чёрное яблоко',
    'ring_lines': 'Линии колец',
    'ring_labels_on_paper': 'Цифры на бумаге',
    'ring_labels_on_bullseye': 'Цифры на яблоке',
    'shot_selected': 'Выбранный выстрел',
    'shot_current_series': 'Выстрелы текущей серии',
    'shot_past_series': 'Выстрелы прошлых серий',
    'shot_number_text': 'Номер внутри пробоины',
    'compass_ring': 'Компас (режим правки)',
    'edit_result_badge': 'Индикатор результата',
    'edit_angle_badge': 'Индикатор угла/часов',
    'bottom_panel_bg': 'Фон панели правки',
    'bottom_panel_text': 'Текст панели правки',
    'crosshair': 'Перекрестие',
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
        title: const Text('Персонализация цвета'),
        bottom: TabBar(controller: _tab, tabs: const [Tab(text: 'ЭЛЕМЕНТЫ'), Tab(text: 'ПРЕСЕТЫ')]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'export' ? _export(context) : _import(context),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Экспорт')),
              PopupMenuItem(value: 'import', child: Text('Импорт')),
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
                            child: const Text('Скрыть мишень', style: TextStyle(color: Colors.white)),
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
              label: const Text('Показать мишень'),
              onPressed: () => setState(() => _showPreviewOnNarrow = true),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildElementsTab(BuildContext context, bool wide) {
    final vm = context.watch<PersonalizationViewModel>();
    return ListView(
      children: [
        if (!wide) SizedBox(height: 160, child: _buildMiniPreview(context)),
        for (final section in _sections.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              section.key,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
            ),
          ),
          for (final key in section.value) _ColorRow(colorKey: key, title: _titles[key]!),
        ],
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(
            onPressed: () => _confirmResetAll(context, vm),
            child: const Text('Сбросить все'),
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
        title: const Text('Сбросить все цвета?'),
        content: const Text('Все настройки цвета будут удалены и восстановлены значения по умолчанию.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              vm.resetAll();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Сбросить всё'),
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
        title: const Text('Экспорт цветовой схемы'),
        content: SingleChildScrollView(child: SelectableText(json)),
        actions: [
          // Выделять пятнадцать строк JSON пальцем на телефоне —
          // мучение, ради которого экспорт и не открывали.
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Схема скопирована')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Закрыть'),
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
        title: const Text('Импорт цветовой схемы'),
        content: TextField(
          controller: controller,
          maxLines: 10,
          decoration: const InputDecoration(hintText: 'Вставьте JSON…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              try {
                vm.importJson(controller.text);
                Navigator.of(dialogContext).pop();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Файл повреждён — импорт отклонён целиком')),
                );
              }
            },
            child: const Text('Импортировать'),
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
      onTap: () => ColorPickerDialog.show(context, colorKey, title),
    );
  }

  void _confirmReset(BuildContext context, PersonalizationViewModel vm) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Сбросить к умолчанию?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              vm.resetKey(colorKey);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
  }
}
