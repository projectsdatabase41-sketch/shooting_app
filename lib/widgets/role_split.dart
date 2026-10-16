import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../state/app_data_store.dart';

/// Одна вкладка для обеих ролей. Включён только «Тренировки» — показывается
/// спортсменский экран, только «Спортсмены» — тренерский; включены оба —
/// сверху переключатель «Мои / Спортсмены», а экраны не пересоздаются
/// (состояние каждого сохраняется). Никакого «режима» нет: контекст данных
/// выставляется по выбранной части.
class RoleSplit extends StatefulWidget {
  final Widget athlete;
  final Widget coach;
  const RoleSplit({super.key, required this.athlete, required this.coach});

  @override
  State<RoleSplit> createState() => _RoleSplitState();
}

class _RoleSplitState extends State<RoleSplit> {
  bool _coach = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final both = store.isAthlete && store.isCoach;
    if (!both) {
      store.setContextSilently(store.isCoach ? WorkMode.coach : WorkMode.athlete);
      return store.isCoach ? widget.coach : widget.athlete;
    }
    store.setContextSilently(_coach ? WorkMode.coach : WorkMode.athlete);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(children: [
        // Своя полоса под строкой состояния; экраны ниже рисуют собственную шапку.
        Container(
          color: cs.surface,
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 8),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.fitness_center), label: Text(tr('Мои'))),
              ButtonSegment(value: true, icon: const Icon(Icons.groups_outlined), label: Text(tr('Спортсмены'))),
            ],
            selected: {_coach},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              setState(() => _coach = s.first);
              store.setContextSilently(_coach ? WorkMode.coach : WorkMode.athlete);
            },
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: IndexedStack(index: _coach ? 1 : 0, children: [widget.athlete, widget.coach]),
          ),
        ),
      ]),
    );
  }
}
