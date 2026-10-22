import '../widgets/app_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/modules_settings.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../widgets/glass_pill.dart';
import '../widgets/settings_draft_scope.dart';
import '../widgets/home_tabs_bar.dart';

/// «Модули»: все рабочие пространства приложения в одном списке. Режимов
/// «спортсмен / тренер» нет — каждое пространство принадлежит модулю,
/// который можно включить или выключить, а порядок на главном экране задаётся
/// перетаскиванием (выше в списке — выше приоритет). Выключенный модуль скрыт
/// и ничего не делает в фоне.
///
/// `SliverReorderableList`, а не `ReorderableListView` внутри `ListView` —
/// вложенный в `shrinkWrap`-режиме падает молча в релизной сборке.
class SettingsModulesScreen extends StatefulWidget {
  final HomeTabsViewModel tabs;
  final Map<String, HomeTabSpec> specs;
  const SettingsModulesScreen({super.key, required this.tabs, required this.specs});

  @override
  State<SettingsModulesScreen> createState() => _SettingsModulesScreenState();
}

class _SettingsModulesScreenState extends State<SettingsModulesScreen> {
  HomeTabsViewModel get tabs => widget.tabs;

  // Роли («Тренировки» / «Я тренер») лежат не в таблице настроек, а в настройках профиля, поэтому
  // отмена экрана их сама не откатывает — запоминаем вход и возвращаем вручную.
  bool? _athlete0, _coach0;

  void _rememberRoles(AppDataStore store) {
    _athlete0 ??= store.isAthlete;
    _coach0 ??= store.isCoach;
  }

  /// Какой модуль отвечает за вкладку; `null` — отдельного модуля нет
  /// (вкладку можно просто скрыть).
  AppModule? _moduleOf(String id) => switch (id) {
        'assistant' => AppModule.assistant,
        'messenger' => AppModule.messenger,
        'notes' => AppModule.notes,
        'finals' => AppModule.finals,
        'drive' => AppModule.drive,
        _ => null,
      };

  /// Включена ли вкладка (её модуль/роль + не скрыта вручную).
  bool _on(String id, AppDataStore store) {
    switch (id) {
      case 'exercises':
        return store.isAthlete;
      case 'athletes':
        return store.isCoach;
    }
    final m = _moduleOf(id);
    if (m != null) return ModulesSettings.isOn(store.db, m) && !tabs.isHidden(id);
    return !tabs.isHidden(id);
  }

  /// Вкладка зависит от роли: пока роль выключена, переключатель недоступен.
  String? _needs(String id, AppDataStore store) {
    // Статистика, задания и ассистент подстраиваются под роли сами.
    if ({'statistics', 'tasks'}.contains(id) && !store.isAthlete && !store.isCoach) {
      return tr('нужен модуль «Тренировки» или «Я тренер»');
    }
    return null;
  }

  void _toggle(String id, bool v, AppDataStore store) {
    switch (id) {
      case 'exercises':
        store.isAthlete = v;
        store.saveSettings();
        store.refreshView();
        return;
      case 'athletes':
        store.isCoach = v;
        store.saveSettings();
        store.refreshView();
        return;
    }
    final m = _moduleOf(id);
    if (m != null) {
      ModulesSettings.set(store.db, m, v);
      if (v) tabs.show(id);
      return;
    }
    v ? tabs.show(id) : tabs.hide(id);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    _rememberRoles(store);
    final theme = Theme.of(context);
    final db = store.db;
    return AnimatedBuilder(
      animation: Listenable.merge([tabs, ModulesSettings.revision]),
      builder: (context, _) {
        // Без «Настроек» (они всегда на месте) и без вкладок, которых нет
        // у этого пользователя (финалы — только в режиме разработчика).
        String labelOf(String id) => id == 'athletes' ? tr('Я тренер') : (widget.specs[id]?.label == null ? id : tr(widget.specs[id]!.label));
        // По алфавиту: порядок плиток меняют на главном экране, здесь только включают и выключают.
        final ids = [
          for (final id in tabs.order)
            if (id != 'settings') id,
        ]..sort((a, b) => labelOf(a).toLowerCase().compareTo(labelOf(b).toLowerCase()));
        Widget row(String id, int index) {
          final spec = widget.specs[id];
          final needs = _needs(id, store);
          final on = _on(id, store);
          return KeyedSubtree(
            key: ValueKey(id),
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(spec?.icon ?? Icons.circle_outlined),
                title: Text(id == 'athletes' ? tr('Я тренер') : (spec?.label == null ? id : tr(spec!.label))),
                subtitle: needs != null ? Text(needs) : (on ? null : Text(tr('выключено'))),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(value: on && needs == null, onChanged: needs != null ? null : (v) => _toggle(id, v, store)),
                ]),
              ),
            ),
          );
        }

        return SettingsDraftScope(
          db: db,
          onRestored: () {
            if (_athlete0 != null && (store.isAthlete != _athlete0 || store.isCoach != _coach0)) {
              store.isAthlete = _athlete0!;
              store.isCoach = _coach0!;
              store.saveSettings();
              store.refreshView();
            }
            tabs.reload();
            ModulesSettings.revision.value++;
          },
          child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassHeader(
            title: Text(tr('Модули'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            actions: [Builder(builder: (ctx) => SettingsDraftScope.confirmButton(ctx, tooltip: tr('Сохранить')))],
          ),
          body: AppBackdrop(kind: 'settings', child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).top + GlassHeader.height + 8)),
              // Размер плиток главного экрана: на широком экране (ноутбук) они не растягиваются.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Размер плиток'), style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      for (final e in const [('xs', 140), ('s', 180), ('m', 240), ('l', 300), ('xl', 360), ('xxl', 420)])
                        _SizeButton(
                          label: e.$1,
                          selected: const [140, 180, 240, 300, 360, 420].reduce((a, b) => (a - tabs.tileMaxPx).abs() <= (b - tabs.tileMaxPx).abs() ? a : b) == e.$2,
                          glass: TileStyle.isGlass(db),
                          onTap: () => tabs.tileMaxPx = e.$2,
                        ),
                    ]),
                  ]),
                ),
              ),
              SliverList.builder(
                itemCount: ids.length,
                itemBuilder: (context, i) => row(ids[i], i),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(tr('Без отдельной вкладки'), style: theme.textTheme.labelLarge),
                ),
              ),
              SliverList.list(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.extension_outlined),
                  title: Text(tr('Сервисы')),
                  subtitle: Text(tr('Свои плитки с внешними сервисами')),
                  value: ModulesSettings.isOn(db, AppModule.services),
                  onChanged: (v) => ModulesSettings.set(db, AppModule.services, v),
                ),
              ]),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          )),
        ));
      },
    );
  }
}

/// Круглая кнопка размера плиток («xs … xxl»): цвет как у остальных кнопок, при «стекле» — прозрачная с контуром.
class _SizeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool glass;
  final VoidCallback onTap;
  const _SizeButton({required this.label, required this.selected, required this.glass, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fill = selected ? cs.primary.withValues(alpha: glass ? 0.55 : 1) : (glass ? Colors.transparent : cs.surfaceContainerHighest);
    final fg = selected ? cs.onPrimary : cs.onSurface;
    return Material(
      color: fill,
      shape: CircleBorder(side: BorderSide(color: selected && !glass ? Colors.transparent : cs.outline.withValues(alpha: 0.55))),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 46, height: 46, child: Center(child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)))),
      ),
    );
  }
}
