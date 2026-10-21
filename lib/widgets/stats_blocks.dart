import 'glass_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/app_data_store.dart';

/// Блоки статистики: порядок и включённость (общие для статистики спортсмена и
/// тренера). Настраиваются кнопкой в шапке (см. [showStatsBlocksSheet]), хранятся
/// в color_prefs.
class StatsBlocks {
  /// id → название (по порядку по умолчанию).
  static const Map<String, String> titles = {
    'tiles': /*tr*/ 'Сводка (плитки)',
    'dynamics': /*tr*/ 'Динамика результата',
    'dist': /*tr*/ 'Распределение по габаритам',
    'group': /*tr*/ 'СТП и кучность',
    'series': /*tr*/ 'Результат по сериям',
  };

  static final ValueNotifier<int> revision = ValueNotifier(0);
  static List<String>? _order;
  static Set<String>? _hidden;

  static String? _get(dynamic db, String k) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(dynamic db, String k, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [k, v]);

  static void _load(dynamic db) {
    if (_order != null) return;
    final saved = (_get(db, 'stats_blocks_order') ?? '').split(',').where(titles.containsKey).toList();
    _order = [...saved, for (final id in titles.keys) if (!saved.contains(id)) id];
    _hidden = (_get(db, 'stats_blocks_hidden') ?? '').split(',').where(titles.containsKey).toSet();
  }

  static List<String> order(dynamic db) {
    _load(db);
    return List.of(_order!);
  }

  static bool visible(dynamic db, String id) {
    _load(db);
    return !_hidden!.contains(id);
  }

  static void save(dynamic db, List<String> order, Set<String> hidden) {
    _order = List.of(order);
    _hidden = Set.of(hidden);
    _put(db, 'stats_blocks_order', order.join(','));
    _put(db, 'stats_blocks_hidden', hidden.join(','));
    revision.value++;
  }
}

/// Кнопка-шестерёнка в шапке статистики: какие блоки показывать и в каком порядке.
Future<void> showStatsBlocksSheet(BuildContext context) {
  final db = context.read<AppDataStore>().db;
  return showGlassSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      var order = StatsBlocks.order(db);
      final hidden = {for (final id in StatsBlocks.titles.keys) if (!StatsBlocks.visible(db, id)) id};
      return StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('Блоки статистики'), style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('Включайте нужные блоки и расставляйте порядок: удержите строку и перетащите.'),
                    style: Theme.of(ctx).textTheme.bodySmall),
              ),
            ),
            Flexible(
              child: ReorderableListView(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                onReorder: (o, n) {
                  if (n > o) n -= 1;
                  setS(() => order.insert(n, order.removeAt(o)));
                  StatsBlocks.save(db, order, hidden);
                },
                children: [
                  for (var i = 0; i < order.length; i++)
                    ReorderableDelayedDragStartListener(
                      key: ValueKey(order[i]),
                      index: i,
                      child: SwitchListTile(
                        secondary: const Icon(Icons.drag_indicator),
                        title: Text(tr(StatsBlocks.titles[order[i]]!)),
                        value: !hidden.contains(order[i]),
                        onChanged: (v) {
                          setS(() => v ? hidden.remove(order[i]) : hidden.add(order[i]));
                          StatsBlocks.save(db, order, hidden);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      );
    },
  );
}
