import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_data_store.dart';
import 'role_switch_scope.dart';

/// Одна вкладка для обеих ролей. Включён только «Тренировки» — спортсменский
/// экран, только «Спортсмены» — тренерский; включены оба — в шапке справа
/// круглая кнопка «М» (мои) / «С» (спортсмены), экраны не пересоздаются
/// (состояние каждого сохраняется). Режима нет: контекст данных выставляется
/// по выбранной части.
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
    return RoleSwitchScope(
      coach: _coach,
      select: (coach) {
        setState(() => _coach = coach);
        store.setContextSilently(_coach ? WorkMode.coach : WorkMode.athlete);
      },
      child: IndexedStack(index: _coach ? 1 : 0, children: [widget.athlete, widget.coach]),
    );
  }
}
