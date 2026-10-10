import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../services/user_profile.dart';
import '../widgets/glass_pill.dart';
import 'settings_data_screen.dart';

/// Анкета спортсмена. При первом открытии обязательна (вид стрельбы, пол,
/// год рождения); позже её можно изменить из настроек ([editing]).
///
/// Порядок на экране сверху вниз: зачем это нужно → вид стрельбы → пол →
/// год рождения → разряд → регион → честное предупреждение → «Продолжить».
class OnboardingScreen extends StatefulWidget {
  final LocalDbService db;
  final bool editing;
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.db, required this.onDone, this.editing = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final Set<String> _disciplines = {...UserProfile.disciplinesOf(widget.db)};
  late String _gender = UserProfile.genderOf(widget.db);
  late int? _year = UserProfile.birthYearOf(widget.db);
  late String _rank = UserProfile.rankOf(widget.db).isEmpty ? UserProfile.ranks.first : UserProfile.rankOf(widget.db);
  late final _region = TextEditingController(text: UserProfile.regionOf(widget.db));
  late final _yearCtl = TextEditingController(text: _year == null ? '' : '$_year');

  static final int maxYear = DateTime.now().year - 6;
  static const int minYear = 1930;

  bool get _valid => _disciplines.isNotEmpty && (_gender == 'm' || _gender == 'f') && _year != null;

  @override
  void dispose() {
    _region.dispose();
    _yearCtl.dispose();
    super.dispose();
  }

  void _submit() {
    UserProfile.save(
      widget.db,
      disciplines: _disciplines.toList(),
      gender: _gender,
      birthYear: _year!,
      rank: _rank == UserProfile.ranks.first ? '' : _rank,
      region: _region.text,
    );
    widget.onDone();
  }

  Widget _section(BuildContext context, String number, String title, Widget child) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              child: Text(number, style: TextStyle(fontSize: 12, color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return PopScope(
      canPop: widget.editing,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
          leading: widget.editing ? null : const SizedBox.shrink(),
          title: Text(tr('Профиль спортсмена'),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 20, 16),
                children: [
                  // 0. Зачем это нужно.
                  Container(
                    padding: const EdgeInsets.all(14),
                    margin: const EdgeInsets.only(bottom: 22),
                    decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.info_outline, color: cs.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          tr('Эти данные нужны, чтобы подобрать упражнения и мишени, сравнивать результаты с нормативами для вашего возраста и пола и — позже — участвовать в финалах и таблице чемпионов. Они хранятся на вашем устройстве; в облако и в общую таблицу попадают только если вы сами это включите.'),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ]),
                  ),
                  // 1. Вид стрельбы.
                  _section(
                    context,
                    '1',
                    tr('Из чего вы стреляете'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final d in UserProfile.disciplines)
                          FilterChip(
                            label: Text(tr(d.$2)),
                            selected: _disciplines.contains(d.$1),
                            onSelected: (v) => setState(() => v ? _disciplines.add(d.$1) : _disciplines.remove(d.$1)),
                          ),
                      ],
                    ),
                  ),
                  // 2. Пол.
                  _section(
                    context,
                    '2',
                    tr('Пол'),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        emptySelectionAllowed: true,
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(value: 'm', label: Text(tr('Мужской')), icon: const Icon(Icons.male)),
                          ButtonSegment(value: 'f', label: Text(tr('Женский')), icon: const Icon(Icons.female)),
                        ],
                        selected: _gender.isEmpty ? <String>{} : {_gender},
                        onSelectionChanged: (s) => setState(() => _gender = s.isEmpty ? '' : s.first),
                      ),
                    ),
                  ),
                  // 3. Год рождения.
                  _section(
                    context,
                    '3',
                    tr('Год рождения'),
                    TextField(
                      controller: _yearCtl,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                          hintText: tr('Например, 2005'), counterText: ''),
                      onChanged: (v) {
                        final y = int.tryParse(v);
                        setState(() => _year =
                            (y != null && y >= minYear && y <= maxYear) ? y : null);
                      },
                    ),
                  ),
                  // 4. Разряд.
                  _section(
                    context,
                    '4',
                    tr('Разряд (необязательно)'),
                    DropdownButtonFormField<String>(
                      initialValue: _rank,
                      isExpanded: true,
                      items: [for (final r in UserProfile.ranks) DropdownMenuItem(value: r, child: Text(tr(r)))],
                      onChanged: (v) => setState(() => _rank = v ?? _rank),
                    ),
                  ),
                  // 5. Регион.
                  _section(
                    context,
                    '5',
                    tr('Регион (необязательно)'),
                    TextField(controller: _region, decoration: InputDecoration(hintText: tr('Например, Москва'))),
                  ),
                  // 6. Предупреждение.
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.errorContainer.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.warning_amber_rounded, color: cs.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          tr('Вводите достоверные данные. Изменить их можно позже в настройках, но смена пола, года рождения или разряда повлияет на сравнение с нормативами и на подтверждение результатов тренером.'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _valid ? _submit : null,
                    child: Text(widget.editing ? tr('Сохранить') : tr('Продолжить')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Предложение синхронизации с облаком (один раз после анкеты): зачем это
/// нужно и три шага регистрации. Можно отложить.
Future<void> showSyncOffer(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final cs = theme.colorScheme;
      Widget step(String n, String title, String text) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: cs.primary,
                child: Text(n, style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  Text(text, style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
          );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.cloud_sync_outlined, color: cs.primary, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(tr('Синхронизация с облаком'),
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                tr('Необязательно, но полезно: резервная копия тренировок, работа на втором устройстве и доступ тренера. Данные лежат в вашей собственной базе — общей базы нет.'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              step('1', tr('Создайте бесплатный проект'),
                  tr('На supabase.com зарегистрируйтесь и создайте проект. Сохраните пароль базы.')),
              step('2', tr('Подготовьте базу'),
                  tr('Выполните скрипт из файла SUPABASE-SETUP.md (раздел «Создать таблицы») в редакторе SQL проекта.')),
              step('3', tr('Подключите в приложении'),
                  tr('Настройки → «Данные и синхронизация»: вставьте адрес проекта и ключ, затем нажмите «Отправить в облако».')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Позже'))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsDataScreen()));
                    },
                    child: Text(tr('Открыть настройки')),
                  ),
                ),
              ]),
            ],
          ),
        ),
      );
    },
  );
}
