import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;

import '../logic/scoring.dart';
import '../models/comment.dart';
import '../models/target_face.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';

/// Диалог ручного добавления выстрела прямо из списка (решение
/// пользователя, пункт 7 списка правок) — без захода на мишень и без
/// фото. Результат и направление связаны в обе стороны: правка одного
/// пересчитывает другое — та же идея, что у слайдера десятых и компаса
/// на самой мишени (`TargetViewModel.setDraftInwardSteps`/
/// `setDraftAngleFromPoint`), только через текстовый ввод, а не жест.
class AddShotDialog extends StatefulWidget {
  const AddShotDialog({super.key});

  static Future<void> show(BuildContext context) {
    final vm = context.read<TargetViewModel>();
    final store = context.read<AppDataStore>();
    return showDialog(
      context: context,
      builder: (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vm),
          ChangeNotifierProvider.value(value: store),
        ],
        child: const AddShotDialog(),
      ),
    );
  }

  @override
  State<AddShotDialog> createState() => _AddShotDialogState();
}

/// Направление — часы (проще для быстрого ввода) или сырые координаты
/// (точнее). Переключатель, а не угадывание режима по первому
/// введённому символу: угадывание слишком легко промахивается мимо
/// того, что человек на самом деле хотел напечатать.
enum _DirMode { hours, coords }

class _AddShotDialogState extends State<AddShotDialog> {
  static const _uuid = Uuid();

  double _xMm = 0;
  double _yMm = 0;
  _DirMode _mode = _DirMode.hours;

  late final TextEditingController _score;
  late final TextEditingController _hour;
  late final TextEditingController _x;
  late final TextEditingController _y;
  final _note = TextEditingController();

  /// Не даёт пересчёту одного поля дёргать поле, которое человек как
  /// раз печатает — иначе курсор скачет на каждый символ.
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _score = TextEditingController(text: '9.0');
    _hour = TextEditingController(text: '12');
    _x = TextEditingController(text: '0.0');
    _y = TextEditingController(text: '0.0');
  }

  @override
  void dispose() {
    _score.dispose();
    _hour.dispose();
    _x.dispose();
    _y.dispose();
    _note.dispose();
    super.dispose();
  }

  double? _parseNum(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  /// Пересчитывает координаты из уже введённого результата — по ЛУЧУ
  /// текущего направления (не трогая угол), как и на самой мишени.
  void _applyScore(TargetFace face) {
    final v = _parseNum(_score.text);
    if (v == null) return;
    var ring = v.floor();
    var decimal = ((v - ring) * 10).round();
    if (decimal >= 10) {
      ring += 1;
      decimal = 0;
    }
    ring = ring.clamp(1, 10);
    decimal = decimal.clamp(0, 9);
    final radius = radiusForScore(ring, decimal, face);
    final angleRad = math.atan2(_xMm, _yMm);
    // В центре угол не определён — оставляем прежний, только если
    // радиус тоже почти нулевой (иначе первый ввод результата 10.0
    // после направления заново "забыл" бы его).
    final rad = (_xMm == 0 && _yMm == 0) ? 0.0 : angleRad;
    _applying = true;
    setState(() {
      _xMm = radius * math.sin(rad);
      _yMm = radius * math.cos(rad);
      _hour.text = '${_clockHour(rad)}';
      _x.text = _xMm.toStringAsFixed(1);
      _y.text = _yMm.toStringAsFixed(1);
    });
    _applying = false;
  }

  void _applyHour(TargetFace face) {
    final h = int.tryParse(_hour.text.trim());
    if (h == null) return;
    final hour = h.clamp(1, 12);
    final radius = math.sqrt(_xMm * _xMm + _yMm * _yMm);
    final rad = (hour % 12) * 30 * math.pi / 180;
    _applying = true;
    setState(() {
      _xMm = radius * math.sin(rad);
      _yMm = radius * math.cos(rad);
      _x.text = _xMm.toStringAsFixed(1);
      _y.text = _yMm.toStringAsFixed(1);
      _score.text = scoreForRadius(radius, face).toStringAsFixed(1);
    });
    _applying = false;
  }

  void _applyCoords(TargetFace face) {
    final x = _parseNum(_x.text);
    final y = _parseNum(_y.text);
    if (x == null || y == null) return;
    _applying = true;
    setState(() {
      _xMm = x;
      _yMm = y;
      final radius = math.sqrt(x * x + y * y);
      _score.text = scoreForRadius(radius, face).toStringAsFixed(1);
      _hour.text = '${_clockHour(math.atan2(x, y))}';
    });
    _applying = false;
  }

  int _clockHour(double angleRad) {
    final deg = angleRad * 180 / math.pi;
    final normalized = deg < 0 ? deg + 360 : deg;
    final hour = (normalized / 30).round() % 12;
    return hour == 0 ? 12 : hour;
  }

  void _save(BuildContext context) {
    final vm = context.read<TargetViewModel>();
    final store = context.read<AppDataStore>();
    if (!vm.canAddShotNow) {
      Navigator.of(context).pop();
      return;
    }
    vm.beginAddNew();
    vm.updateDraftPosition(_xMm, _yMm);
    vm.confirmEdit();
    final noteText = _note.text.trim();
    if (noteText.isNotEmpty && vm.session.shots.isNotEmpty) {
      final newShot = vm.session.shots.last;
      CommentsRepository(store.db).add(Comment(
        id: _uuid.v4(),
        sessionId: vm.session.id,
        level: CommentLevel.shot,
        shotId: newShot.id,
        authorRole: store.workMode == WorkMode.coach ? AuthorRole.coach : AuthorRole.athlete,
        text: noteText,
        createdAt: DateTime.now(),
      ));
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final face = vm.face;

    return AlertDialog(
      title: const Text('Добавить выстрел'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _score,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Результат'),
                    onChanged: (_) {
                      if (!_applying) _applyScore(face);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _mode == _DirMode.hours
                      ? TextField(
                          controller: _hour,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Часы (1–12)'),
                          onChanged: (_) {
                            if (!_applying) _applyHour(face);
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_DirMode>(
                segments: const [
                  ButtonSegment(value: _DirMode.hours, label: Text('Часы')),
                  ButtonSegment(value: _DirMode.coords, label: Text('X / Y')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
            if (_mode == _DirMode.coords) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _x,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'X, мм'),
                      onChanged: (_) {
                        if (!_applying) _applyCoords(face);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _y,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(labelText: 'Y, мм'),
                      onChanged: (_) {
                        if (!_applying) _applyCoords(face);
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Заметка', alignLabelWithHint: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(onPressed: () => _save(context), child: const Text('Сохранить')),
      ],
    );
  }
}
