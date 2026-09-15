import 'package:flutter/material.dart';

import '../state/home_tabs_view_model.dart';
import '../widgets/home_tabs_bar.dart';

/// "Рабочие пространства" — тот же список вкладок, что и в нижней
/// навигации, только не всплывающим крестиком, а обычным переключателем:
/// сюда возвращаются вкладки, скрытые с главного экрана (решение
/// пользователя — там их скрыть куда быстрее, чем через настройки, но
/// вернуть назад ДОЛЖНО быть можно именно отсюда).
///
/// `SliverReorderableList`, а не `ReorderableListView` внутри `ListView`
/// — вложенный `ReorderableListView` в `shrinkWrap`-режиме падает молча
/// (в релизной сборке — серый экран без текста ошибки), это единственный
/// официально поддерживаемый способ смешать перетаскиваемый список со
/// статичным содержимым в одной прокрутке.
///
/// `tabs` передан явно, а не через `Provider` — этот экран открывается
/// `Navigator.push` на КОРНЕВОЙ навигатор приложения (у `HomeShell` нет
/// своего), а Provider, объявленный внутри поддерева `HomeShell`,
/// пушнутому поверх всего маршруту не виден.
class SettingsHomeTabsScreen extends StatelessWidget {
  final Map<String, HomeTabSpec> specs;
  final HomeTabsViewModel tabs;
  const SettingsHomeTabsScreen({super.key, required this.specs, required this.tabs});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: tabs,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final visible = tabs.visible;
    final hidden = tabs.hidden;

    Widget tile(String id, {required bool isVisible}) => Card(
          key: ValueKey(id),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: Icon(specs[id]?.icon ?? Icons.circle_outlined),
            title: Text(specs[id]?.label ?? id),
            subtitle: isVisible ? null : const Text('скрыта'),
            trailing: Switch(
              value: isVisible,
              onChanged: isVisible
                  ? (tabs.canHide(id) ? (_) => tabs.hide(id) : null)
                  : (_) => tabs.show(id),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Рабочие пространства')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Удержать и перетащить — поменять порядок на главном экране. '
                'То же самое можно и прямо там: удержать значок, отпустить — появится крестик.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
            sliver: SliverReorderableList(
              itemCount: visible.length,
              onReorder: tabs.move,
              itemBuilder: (context, index) {
                final id = visible[index];
                return ReorderableDragStartListener(
                  key: ValueKey(id),
                  index: index,
                  child: tile(id, isVisible: true),
                );
              },
            ),
          ),
          if (hidden.isNotEmpty) ...[
            const SliverToBoxAdapter(child: Divider(height: 24)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Скрытые', style: theme.textTheme.labelLarge),
              ),
            ),
            SliverList.list(children: [for (final id in hidden) tile(id, isVisible: false)]),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}
