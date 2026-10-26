import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../models/comment.dart';
import '../models/target_color_scheme.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';
import 'final_run_screen.dart' show ShotPad;

/// Режим концентрации: чёрный экран («как будто экран выключен»), по центру круг мишени без бумажного листа,
/// выстрел ставится касанием с лупой. Только яркие кнопки: справа вверху «свернуть», под мишенью «заметка»,
/// в самом низу «отмена выстрела».
class FocusTrainingScreen extends StatefulWidget {
  const FocusTrainingScreen({super.key});

  /// Открывает режим поверх экрана тренировки, передавая ему её вью-модель.
  static Future<void> open(BuildContext context) {
    final vm = context.read<TargetViewModel>();
    return Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (_, __, ___) => ChangeNotifierProvider<TargetViewModel>.value(value: vm, child: const FocusTrainingScreen()),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  State<FocusTrainingScreen> createState() => _FocusTrainingScreenState();
}

class _FocusTrainingScreenState extends State<FocusTrainingScreen> {
  bool _holding = false;

  /// Мишень на чёрном: колец до последнего видно, лист не рисуется квадратом (круг вырезается по краю мишени).
  static final TargetColorScheme _scheme = TargetColorScheme.defaultScheme;

  Future<void> _note(TargetViewModel vm) async {
    final shot = vm.selectedShot ?? (vm.session.shots.isEmpty ? null : vm.session.shots.last);
    if (shot == null) return;
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: Text(tr('Заметка к выстрелу'), style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(hintText: tr('Что почувствовали?'), hintStyle: const TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(tr('Сохранить'))),
        ],
      ),
    );
    ctl.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    final store = context.read<AppDataStore>();
    CommentsRepository(store.db).add(Comment(
      id: const Uuid().v4(),
      sessionId: vm.session.id,
      level: CommentLevel.shot,
      shotId: shot.id,
      authorRole: store.workMode == WorkMode.coach ? AuthorRole.coach : AuthorRole.athlete,
      text: text,
      createdAt: DateTime.now(),
    ));
    vm.noteExternalEdit();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    // Кнопки яркие: белая заливка, чёрный значок/текст.
    final bright = FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      minimumSize: const Size(0, 48),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    );
    final series = vm.session.shots.where((s) => s.seriesNo == vm.currentSeriesNo).toList();
    final canShoot = vm.canAddShotNow && !vm.isEditing;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final side = (box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight) - 24;
                return Center(
                  child: SizedBox(
                    width: side,
                    height: side,
                    // Круг мишени без квадратного листа: всё за кольцами чёрное.
                    child: ClipOval(
                      child: ColoredBox(
                        color: Colors.black,
                        child: ShotPad(
                          face: vm.face,
                          colors: _scheme,
                          marks: [for (final s in series) Offset(s.xMm, s.yMm)],
                          enabled: canShoot,
                          onHold: (v) => setState(() => _holding = v),
                          onShot: (mm) => vm.addShotAt(mm.dx, mm.dy),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: bright,
                  onPressed: vm.session.shots.isEmpty ? null : () => _note(vm),
                  icon: const Icon(Icons.edit_note),
                  label: Text(tr('Заметка')),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: bright,
                  onPressed: vm.session.shots.isEmpty || !vm.canEditShots ? null : vm.undoLastShot,
                  icon: const Icon(Icons.undo),
                  label: Text(tr('Отменить выстрел')),
                ),
              ),
            ),
          ]),
          // Свернуть режим — круглая яркая кнопка справа вверху.
          Positioned(
            top: 8,
            right: 8,
            child: IgnorePointer(
              ignoring: _holding,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(52, 52)),
                tooltip: tr('Свернуть'),
                icon: const Icon(Icons.close_fullscreen),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          if (!vm.canAddShotNow)
            Positioned(
              left: 16,
              right: 80,
              top: 18,
              child: Text(tr('Начните тренировку, чтобы ставить выстрелы'), style: const TextStyle(color: Colors.white70)),
            ),
        ]),
      ),
    );
  }
}
