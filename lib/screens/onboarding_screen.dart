import '../widgets/glass_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
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
  late DateTime? _date = UserProfile.birthDateOf(widget.db);
  late String _rank = UserProfile.rankOf(widget.db).isEmpty ? UserProfile.ranks.first : UserProfile.rankOf(widget.db);
  late final _first = TextEditingController(text: UserProfile.firstNameOf(widget.db));
  late final _last = TextEditingController(text: UserProfile.lastNameOf(widget.db));
  late final _region = TextEditingController(text: UserProfile.regionOf(widget.db));
  late final _dateCtl = TextEditingController(text: _date == null ? '' : _fmt(_date!));

  static final DateTime maxDate = DateTime(DateTime.now().year - 6, DateTime.now().month, DateTime.now().day);
  static final DateTime minDate = DateTime(1930);

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _fmt(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

  /// ДД.ММ.ГГГГ → дата (с проверкой календаря и возраста от 6 лет); иначе null.
  static DateTime? parseDate(String v) {
    final m = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})$').firstMatch(v);
    if (m == null) return null;
    final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
    final dt = DateTime(y, mo, d);
    if (dt.day != d || dt.month != mo || dt.year != y) return null; // 31.02 и т. п.
    return (dt.isBefore(minDate) || dt.isAfter(maxDate)) ? null : dt;
  }

  bool get _valid => _first.text.trim().isNotEmpty && _last.text.trim().isNotEmpty && _disciplines.isNotEmpty && (_gender == 'm' || _gender == 'f') && _date != null;

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _region.dispose();
    _dateCtl.dispose();
    super.dispose();
  }

  void _submit() {
    UserProfile.save(
      widget.db,
      firstName: _first.text,
      lastName: _last.text,
      disciplines: _disciplines.toList(),
      gender: _gender,
      birthDate: _date!,
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
          title: Text(tr('Мой профиль'),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          actions: [
            if (widget.editing) GlassCircleButton(icon: const BoldIcon(Icons.check), tooltip: tr('Сохранить'), onTap: _valid ? _submit : null),
          ],
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
                          tr('Данные о вас помогут улучшить качество ответов ИИ и подобрать упражнения и нормативы. Они хранятся на вашем устройстве. Указывайте достоверные данные: их изменение позже может привести к ошибкам в сохранённой информации.'),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ]),
                  ),
                  // 1. Имя и фамилия.
                  _section(
                    context,
                    '1',
                    tr('Имя и фамилия'),
                    AutofillGroup(child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _first,
                          autofillHints: const [AutofillHints.givenName],
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(hintText: tr('Имя')),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _last,
                          autofillHints: const [AutofillHints.familyName],
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(hintText: tr('Фамилия')),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ])),
                  ),
                  // 2. Вид стрельбы.
                  _section(
                    context,
                    '2',
                    tr('Из чего вы стреляете'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final d in UserProfile.disciplines)
                          if (!UserProfile.devOnlyDisciplines.contains(d.$1) || friendlyErrorDevMode || _disciplines.contains(d.$1))
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
                    '3',
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
                  // 3. Дата рождения.
                  _section(
                    context,
                    '4',
                    tr('Дата рождения'),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _dateCtl,
                          keyboardType: TextInputType.number,
                          maxLength: 10,
                          inputFormatters: [_DateMaskFormatter()],
                          decoration: InputDecoration(hintText: tr('ДД.ММ.ГГГГ'), counterText: ''),
                          onChanged: (v) => setState(() => _date = parseDate(v)),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Календарь'),
                        icon: const Icon(Icons.calendar_month_outlined),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _date ?? DateTime(maxDate.year - 15, 6, 15),
                            firstDate: minDate,
                            lastDate: maxDate,
                            initialEntryMode: DatePickerEntryMode.calendarOnly,
                          );
                          if (picked != null) {
                            _dateCtl.text = _fmt(picked);
                            setState(() => _date = picked);
                          }
                        },
                      ),
                    ]),
                  ),
                  // 4. Разряд.
                  _section(
                    context,
                    '5',
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
                    '6',
                    tr('Регион (необязательно)'),
                    TextField(controller: _region, decoration: InputDecoration(hintText: tr('Например, Москва'))),
                  ),
                ],
              ),
            ),
            if (!widget.editing)
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
  return showGlassSheet<void>(
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

/// Подставляет точки при вводе цифр: 15032000 → 15.03.2000.
class _DateMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) {
    final digits = value.text.replaceAll(RegExp(r'\D'), '');
    final cut = digits.length > 8 ? digits.substring(0, 8) : digits;
    final buf = StringBuffer();
    for (var i = 0; i < cut.length; i++) {
      if (i == 2 || i == 4) buf.write('.');
      buf.write(cut[i]);
    }
    final text = buf.toString();
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
