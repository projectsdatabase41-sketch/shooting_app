import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';

/// Одна вкладка для обеих ролей, без переключателей режима.
/// • только спортсмен — только его экран;
/// • только тренер — тренерский экран (свой список спортсменов);
/// • и то и другое — общий выпадающий список «Чьи данные»: «Я» и спортсмены.
class RoleSplit extends StatefulWidget {
  /// Экран своих данных; [top] — выбор «чьи данные» (вставить в верх списка).
  final Widget Function(Widget? top) athlete;

  /// Тренерский экран; [athleteId] — выбранный спортсмен, [top] — тот же выбор.
  final Widget Function(Widget? top, String? athleteId) coach;

  /// `true` — в списке отдельные спортсмены (статистика); `false` — один пункт
  /// «Мои спортсмены» (задания: тренерский экран и так показывает всех).
  final bool perAthlete;
  const RoleSplit({super.key, required this.athlete, required this.coach, this.perAthlete = true});

  @override
  State<RoleSplit> createState() => _RoleSplitState();
}

class _RoleSplitState extends State<RoleSplit> {
  String _who = 'me'; // 'me' | id спортсмена | 'all'
  List<CoachAthlete>? _athletes;

  Widget _picker(List<CoachAthlete> athletes) {
    // «Я» показываем не всегда: на экране заданий (perAthlete == false) у
    // тренера без спортсменов выбор «Я» бессмыслен — задание себе там не
    // создать, и пункт только путает (отзыв 23.11: «если из данных только я,
    // то нет возможности создать задание для меня — смысл показывать Я»).
    final showSelf = widget.perAthlete || athletes.isNotEmpty;
    final current = showSelf ? _who : 'all';
    return DropdownButtonFormField<String>(
      key: ValueKey('who-$current'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(labelText: tr('Чьи данные')),
      items: [
        if (showSelf) DropdownMenuItem(value: 'me', child: Text(tr('Я'))),
        if (widget.perAthlete)
          for (final a in athletes) DropdownMenuItem(value: a.id, child: Text(a.name))
        else
          DropdownMenuItem(value: 'all', child: Text(tr('Мои спортсмены'))),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _who = v);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final both = store.isAthlete && store.isCoach;
    if (!both) {
      store.setContextSilently(store.isCoach ? WorkMode.coach : WorkMode.athlete);
      return store.isCoach ? widget.coach(null, null) : widget.athlete(null);
    }
    final athletes = _athletes ??= CoachAccessService(store.db).listAthletes();
    // Тот же признак, что в _picker: без спортсменов на экране заданий «Я»
    // не показываем и режим держим тренерским, иначе подпись списка и
    // содержимое расходятся.
    final showSelf = widget.perAthlete || athletes.isNotEmpty;
    final me = _who == 'me' && showSelf;
    store.setContextSilently(me ? WorkMode.athlete : WorkMode.coach);
    final top = _picker(athletes);
    return me ? widget.athlete(top) : widget.coach(top, widget.perAthlete ? _who : null);
  }
}
