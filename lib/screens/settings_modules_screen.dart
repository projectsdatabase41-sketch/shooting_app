import '../logic/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/modules_settings.dart';
import '../state/app_data_store.dart';
import '../state/home_tabs_view_model.dart';
import '../widgets/glass_pill.dart';
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

  /// Какой модуль отвечает за вкладку; `null` — отдельного модуля нет
  /// (вкладку можно просто скрыть).
  AppModule? _moduleOf(String id) => switch (id) {
        'assistant' => AppModule.assistant,
        'messenger' => AppModule.messenger,
        'notes' => AppModule.notes,
        'finals' => AppModule.finals,
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
    final theme = Theme.of(context);
    final db = store.db;
    return AnimatedBuilder(
      animation: Listenable.merge([tabs, ModulesSettings.revision]),
      builder: (context, _) {
        // Без «Настроек» (они всегда на месте) и без вкладок, которых нет
        // у этого пользователя (финалы — только в режиме разработчика).
        final ids = [
          for (final id in tabs.order)
            if (id != 'settings' && (id != 'finals' || friendlyErrorDevMode)) id,
        ];
        Widget row(String id, int index) {
          final spec = widget.specs[id];
          final needs = _needs(id, store);
          final on = _on(id, store);
          return ReorderableDelayedDragStartListener(
            key: ValueKey(id),
            index: index,
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(spec?.icon ?? Icons.circle_outlined),
                title: Text(id == 'athletes' ? tr('Я тренер') : (spec?.label == null ? id : tr(spec!.label))),
                subtitle: needs != null ? Text(needs) : (on ? null : Text(tr('выключено'))),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(value: on && needs == null, onChanged: needs != null ? null : (v) => _toggle(id, v, store)),
                  const Icon(Icons.drag_handle),
                ]),
              ),
            ),
          );
        }

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: GlassHeader(
            title: Text(tr('Модули'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).top + GlassHeader.height + 8)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    tr('Включайте нужные модули и расставляйте их по приоритету: удержите строку, затем перетащите (простой свайп просто листает список). Режима «спортсмен / тренер» нет — «Тренировка» и «Спортсмены» можно включить вместе или по отдельности. Выключенный модуль скрыт и не работает в фоне.'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              SliverReorderableList(
                itemCount: ids.length,
                onReorder: (oldIndex, newIndex) {
                  final list = List.of(ids);
                  var target = newIndex;
                  if (target > oldIndex) target -= 1;
                  final moved = list.removeAt(oldIndex);
                  list.insert(target.clamp(0, list.length), moved);
                  tabs.setOrder([...list, 'settings']);
                },
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
                  secondary: const Icon(Icons.offline_bolt_outlined),
                  title: Text(tr('Локальный ИИ')),
                  subtitle: Text(tr('Работает без интернета')),
                  value: ModulesSettings.isOn(db, AppModule.localAi),
                  onChanged: (v) => ModulesSettings.set(db, AppModule.localAi, v),
                ),
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
          ),
        );
      },
    );
  }
}
