import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../services/coach_access_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import 'coach_athletes_chat_screen.dart';
import 'coach_diary_screen.dart';

/// Список подключённых спортсменов у тренера (мульти-спортсменский
/// режим — решение пользователя: "как список создания упражнений, так
/// же создание подключений к спортсменам"). Тап — открыть дневник
/// этого спортсмена; "+" внизу слева — добавить нового, как у
/// спортсмена при создании упражнения.
///
/// Сетка в два столбца, кнопки квадратные (решение пользователя).
/// Перетаскивание сделано на встроенных `LongPressDraggable`/
/// `DragTarget` — без отдельного пакета под двухколоночную сетку с
/// "прилипанием к пальцу". Долгое нажатие БЕЗ движения — это тоже
/// перетаскивание, которое заканчивается на той же самой
/// ячейке: там это ловится как частный случай "перетащили сами на
/// себя" и открывает настройки спортсмена, а не меняет порядок
/// (решение пользователя: "удержал и отпустил, позиция не изменилась —
/// открыть настройки"). Перетаскивание на ДРУГУЮ ячейку меняет
/// спортсменов местами.
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

  /// Перетащили одного спортсмена на ячейку другого — меняются местами
  /// (простой swap, а не вставка со сдвигом остальных: для сетки это
  /// понятнее — карточка всегда попадает ровно туда, куда её положили).
  void _swap(String draggedId, String targetId) {
    if (draggedId == targetId) return;
    final di = _athletes.indexWhere((a) => a.id == draggedId);
    final ti = _athletes.indexWhere((a) => a.id == targetId);
    if (di < 0 || ti < 0) return;
    setState(() {
      final tmp = _athletes[di];
      _athletes[di] = _athletes[ti];
      _athletes[ti] = tmp;
    });
    _access.reorderAthletes([for (final a in _athletes) a.id]);
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
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              // Первая плитка — «Чат» со спортсменами, дальше сами спортсмены.
              itemCount: _athletes.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CoachAthletesChatScreen(access: _access),
                      )),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.forum_outlined, size: 28, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(height: 8),
                          Text('Чат', style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                    ),
                  );
                }
                final athlete = _athletes[i - 1];
                return _AthleteCell(
                  key: ValueKey(athlete.id),
                  athlete: athlete,
                  onTap: () => _openDiary(athlete),
                  onSettings: () => _openAthleteDialog(existing: athlete),
                  onDropped: (draggedId) => _swap(draggedId, athlete.id),
                );
              },
            ),
      // Справа внизу — как «новая запись» в дневнике (единообразие).
      floatingActionButton: FloatingActionButton(
        tooltip: 'Добавить спортсмена',
        onPressed: () => _openAthleteDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Одна квадратная кнопка спортсмена в сетке — тап открывает дневник,
/// долгое нажатие-и-отпускание НА МЕСТЕ открывает настройки (см.
/// объяснение у класса экрана), перетаскивание на другую ячейку меняет
/// спортсменов местами.
class _AthleteCell extends StatelessWidget {
  final CoachAthlete athlete;
  final VoidCallback onTap;
  final VoidCallback onSettings;
  final void Function(String draggedAthleteId) onDropped;

  const _AthleteCell({
    super.key,
    required this.athlete,
    required this.onTap,
    required this.onSettings,
    required this.onDropped,
  });

  Widget _card(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.person_outline, size: 28),
                const SizedBox(height: 8),
                Text(
                  athlete.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (details) {
        if (details.data == athlete.id) {
          onSettings();
        } else {
          onDropped(details.data);
        }
      },
      builder: (context, candidateData, rejectedData) => LongPressDraggable<String>(
        data: athlete.id,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 150, height: 150, child: _card(context)),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: _card(context)),
        child: _card(context),
      ),
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
