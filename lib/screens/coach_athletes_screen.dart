import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import 'coach_diary_screen.dart';

/// Список подключённых спортсменов у тренера (мульти-спортсменский
/// режим — решение пользователя: "как список создания упражнений, так
/// же создание подключений к спортсменам"). Тап — открыть дневник
/// этого спортсмена; "+" внизу слева — добавить нового, как у
/// спортсмена при создании упражнения.
///
/// Перетаскивание для смены порядка — обычный `ReorderableListView`
/// (не двухколоночная сетка с "прилипанием к пальцу": Flutter не даёт
/// такой виджет из коробки, а тянуть отдельный пакет ради одной сетки
/// с перетаскиванием — лишнее). Правка/удаление — через кнопку на
/// самой строке, а не долгим нажатием: два смысла у одного жеста
/// (потянуть vs открыть) было бы неоднозначно.
class CoachAthletesScreen extends StatefulWidget {
  const CoachAthletesScreen({super.key});

  @override
  State<CoachAthletesScreen> createState() => _CoachAthletesScreenState();
}

class _CoachAthletesScreenState extends State<CoachAthletesScreen> {
  late final CoachAccessService _access;
  late List<CoachAthlete> _athletes;

  @override
  void initState() {
    super.initState();
    _access = CoachAccessService(context.read<AppDataStore>().db);
    _athletes = _access.listAthletes();
  }

  void _refresh() => setState(() => _athletes = _access.listAthletes());

  Future<void> _openAthleteDialog({CoachAthlete? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final keyCtrl = TextEditingController(text: existing?.anonKey ?? '');
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');
    final result = await showDialog<_AthleteDialogResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Новый спортсмен' : 'Спортсмен'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Имя спортсмена'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Адрес базы',
                  hintText: 'https://xxxx.supabase.co',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: 'Публичный ключ (anon)'),
                obscureText: true,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenCtrl,
                decoration: const InputDecoration(labelText: 'Токен доступа'),
                obscureText: true,
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(const _AthleteDialogResult.delete()),
              child: Text('Удалить', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty ||
                  urlCtrl.text.trim().isEmpty ||
                  keyCtrl.text.trim().isEmpty ||
                  tokenCtrl.text.trim().isEmpty) {
                return;
              }
              Navigator.of(ctx).pop(_AthleteDialogResult.save(CoachAthlete(
                id: existing?.id ?? const Uuid().v4(),
                name: nameCtrl.text,
                url: urlCtrl.text,
                anonKey: keyCtrl.text,
                token: tokenCtrl.text,
              )));
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result.delete && existing != null) {
      _access.deleteAthlete(existing.id);
    } else if (result.athlete != null) {
      _access.saveAthlete(result.athlete!);
    }
    _refresh();
  }

  void _openDiary(CoachAthlete athlete) {
    _access.selectAthlete(athlete);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CoachDiaryScreen(athleteName: athlete.name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Спортсмены')),
      body: _athletes.isEmpty
          ? const EmptyState(
              icon: Icons.groups_outlined,
              text: 'Пока никого не подключили — нажмите "+", чтобы добавить спортсмена.',
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              itemCount: _athletes.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                setState(() {
                  final a = _athletes.removeAt(oldIndex);
                  _athletes.insert(newIndex, a);
                });
                _access.reorderAthletes([for (final a in _athletes) a.id]);
              },
              itemBuilder: (context, i) {
                final athlete = _athletes[i];
                return Card(
                  key: ValueKey(athlete.id),
                  child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(athlete.name),
                    trailing: IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Настройки спортсмена',
                      onPressed: () => _openAthleteDialog(existing: athlete),
                    ),
                    onTap: () => _openDiary(athlete),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAthleteDialog(),
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }
}

class _AthleteDialogResult {
  final CoachAthlete? athlete;
  final bool delete;
  const _AthleteDialogResult.save(this.athlete) : delete = false;
  const _AthleteDialogResult.delete()
      : athlete = null,
        delete = true;
}
