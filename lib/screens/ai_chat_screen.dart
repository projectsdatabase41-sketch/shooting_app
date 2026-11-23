import '../services/app_lock.dart';
import '../theme/backdrop_tint.dart';
import '../widgets/glass_route.dart';
import 'dart:async';
import 'dart:math' as math;
import '../logic/friendly_error.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:uuid/uuid.dart';

import '../logic/ai_context.dart';
import '../services/ai_settings.dart';
import '../models/coach_note.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../services/chat_preferences.dart';
import '../services/coach_notes_repository.dart';
import '../services/feedback_service.dart';
import '../state/ai_chat_view_model.dart';
import '../services/chat_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/ai_chart_view.dart';
import '../widgets/glass_pill.dart';
import '../widgets/raised_3d_button.dart';
import '../i18n/i18n.dart';
import '../voice/voice_control.dart';
import '../widgets/messenger_bubble.dart';
import '../widgets/voice_recording_indicator.dart';

/// Чат с ассистентом по результатам стрельбы.
///
/// Одна лента: графики и таблицы рисуются прямо в сообщениях. Отдельная
/// страница «Графики» была, но её убрали — её горизонтальный свайп
/// конфликтовал с листанием рабочего стола, а содержимое дублировало
/// то, что уже видно в переписке.
///
/// Экран открывается из трёх мест, и от места зависит `scope`, который
/// уходит модели: из настроек — общий разговор, с экрана мишени — вопрос
/// по идущей тренировке, из заметки к выстрелу — вопрос по выстрелу.
class AiChatScreen extends StatelessWidget {
  final AiScope scope;
  final TrainingSession? session;
  final Exercise? exercise;
  final TargetFace? face;
  final Shot? shot;

  /// Встроен ли чат в другой экран (страница рабочего стола).
  ///
  /// Тогда своей шапки у него быть не должно: заголовок и кнопки уже
  /// есть у рабочего стола, а вторая полоса сверху съедала бы место и
  /// путала — какая из них к чему относится.
  final bool embedded;

  /// Чат тренера (главный экран тренера, раздел 8 ТЗ) — вместо
  /// собственных тренировок тренера ассистенту отдаются тренировки
  /// ВЫБРАННОГО спортсмена ([sessionsOverride], уже сведённые к
  /// `TrainingSession` из RPC-ответов `CoachAccessService`), и
  /// разрешается предлагать заметку в дневник тренера (```note).
  final bool coachMode;
  final List<TrainingSession>? sessionsOverride;
  final String Function(TrainingSession)? exerciseNameOfOverride;

  /// Чьи данные в [sessionsOverride] (имя спортсмена); `null` — пользователя.
  final String? ownerLabel;

  /// Данные спортсменов тренера (общий ассистент видит всех).
  final List<AiAthleteData> athletes;

  /// Комментарии к выстрелам/сериям/сессии для режима тренера.
  final List<Map<String, dynamic>> comments;

  const AiChatScreen({
    super.key,
    this.scope = AiScope.general,
    this.session,
    this.exercise,
    this.face,
    this.shot,
    this.embedded = false,
    this.coachMode = false,
    this.sessionsOverride,
    this.exerciseNameOfOverride,
    this.ownerLabel,
    this.athletes = const [],
    this.comments = const [],
  });

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppDataStore>();
    // Модель разговора живёт в корне приложения и переживает закрытие
    // экрана — здесь она не создаётся, а только берётся и настраивается
    // на текущий источник вопроса.
    final vm = context.read<AiChatViewModel>();
    vm.useContext(() => AiContext(
          scope: scope,
          session: session,
          exercise: exercise,
          face: face,
          shot: shot,
          allSessions: sessionsOverride ?? store.sessions,
          existingExercises: store.exercises,
          // Код в подпись обязательно: пользователь спрашивает
          // «а по упражнению 234», и это именно код, а не название.
          // Без него модель просто не находит, о чём речь.
          exerciseNameOf: exerciseNameOfOverride ??
              (s) => store.exerciseFor(s)?.label ?? tr('без упражнения'),
          coachMode: coachMode,
          ownerLabel: ownerLabel,
          athletes: athletes,
          comments: comments,
        ));
    return _AiChatBody(embedded: embedded, coachMode: coachMode);
  }
}

/// Ручной выбор модели чата (AiSettings.chatModelChoice): «Авто» (как
/// решают настройки ИИ), локальная (если скачана), любая из облачной
/// цепочки без перебора остальных.
class _ModelPickerButton extends StatefulWidget {
  final AiSettings settings;
  const _ModelPickerButton({required this.settings});

  @override
  State<_ModelPickerButton> createState() => _ModelPickerButtonState();
}

class _ModelPickerButtonState extends State<_ModelPickerButton> {
  String _shortLabel(String choice) {
    if (choice == 'auto') return tr('Авто');
    // Модель облака вида "vendor/name:free" — короткая часть после слэша.
    final short = choice.split('/').last.split(':').first;
    return short.length > 14 ? '${short.substring(0, 14)}…' : short;
  }

  Future<void> _open() async {
    final s = widget.settings;
    if (!mounted) return;
    final choice = await showGlassSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = s.chatModelChoice;
        Widget tile(
                {required String value,
                required String title,
                String? subtitle,
                bool enabled = true}) =>
            ListTile(
              title: Text(title),
              subtitle: subtitle == null ? null : Text(subtitle),
              trailing: current == value ? const Icon(Icons.check) : null,
              enabled: enabled,
              onTap: enabled ? () => Navigator.of(ctx).pop(value) : null,
            );
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(tr('Модель ответа'))),
              tile(
                  value: 'auto',
                  title: tr('Авто'),
                  subtitle: tr('Как решают настройки ИИ')),
              const Divider(),
              for (final m in s.models) tile(value: m, title: m),
            ],
          ),
        );
      },
    );
    if (choice != null && choice != s.chatModelChoice) {
      setState(() => s.chatModelChoice = choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCircleButton(
      icon: const Icon(Icons.tune),
      tooltip: tr('Модель: {label}',
          {'label': _shortLabel(widget.settings.chatModelChoice)}),
      onTap: _open,
    );
  }
}

class _AiChatBody extends StatefulWidget {
  final bool embedded;
  final bool coachMode;

  const _AiChatBody({this.embedded = false, this.coachMode = false});

  @override
  State<_AiChatBody> createState() => _AiChatBodyState();
}

class _AiChatBodyState extends State<_AiChatBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Фото к следующему вопросу — только пока «Модель ответа» (кнопка в
  /// шапке) реально умеет смотреть, см. `_visionAvailable`.
  Uint8List? _pendingImage;

  // --- Голосовой ввод в композере (просьба владельца 23.11, п. 2). ---

  /// Идёт распознавание: композер заменён на панель записи.
  bool _listening = false;

  /// Секунды с начала распознавания — ведёт Timer самого экрана (требование B),
  /// а не виджет индикатора: там Timer'ов не заводят принципиально.
  Duration _voiceElapsed = Duration.zero;
  Timer? _voiceTimer;

  /// Счётчик сеансов: после отмены прослушанный listenOnce может всё ещё
  /// додумывать и вернуться с текстом — по несовпадению номера результат
  /// выбрасывается, а не попадает в поле уже после отмены.
  int _voiceGen = 0;

  /// Пользователь (или лимит 30 с) попросил остановиться: результат ещё
  /// может прийти и должен быть вставлен, поэтому это НЕ отмена.
  bool _voiceStopRequested = false;

  /// Максимум ~30 секунд на фразу (требование B): дольше системный
  /// распознаватель всё равно не держит, а экран не должен зависнуть
  /// в панели записи навсегда.
  static const _voiceMaxListen = Duration(seconds: 30);

  @override
  void dispose() {
    _voiceTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Микрофон: запускает системное распознавание (speech_to_text, бесплатно;
  /// язык берётся из языка интерфейса — I18n.code, см. VoiceControl.listenOnce).
  Future<void> _startVoiceInput() async {
    if (_listening) return;
    final gen = ++_voiceGen;
    _voiceStopRequested = false;
    setState(() {
      _listening = true;
      _voiceElapsed = Duration.zero;
    });
    // Таймер на экране (требование B): тикает по секунде для индикатора
    // и следит за лимитом 30 с.
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (gen != _voiceGen || !mounted) {
        t.cancel();
        return;
      }
      setState(() => _voiceElapsed += const Duration(seconds: 1));
      if (!_voiceStopRequested && _voiceElapsed >= _voiceMaxListen) {
        // Лимит: не отмена (попросить «не вставлять» некто не просил) —
        // останавливаем как обычный стоп: что услышано, то вставится.
        _voiceStopRequested = true;
        unawaited(VoiceControl.instance.stop());
      }
    });
    final String? recognized;
    try {
      recognized = await VoiceControl.instance
          .listenOnce(listenFor: _voiceMaxListen);
    } finally {
      _voiceTimer?.cancel();
      _voiceTimer = null;
    }
    // Отмена (крестик) или экран закрыт — результат выбрасываем.
    if (gen != _voiceGen || !mounted) return;
    setState(() => _listening = false);
    final text = recognized?.trim() ?? '';
    if (text.isEmpty) {
      // listenOnce возвращает null и без микрофона, и без разрешения, и при
      // тишине — одна понятная подсказка вместо трёх разных (ошибки
      // различить со стороны нельзя, см. требование C).
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(tr('Не удалось распознать речь'))));
      return;
    }
    // Вставляем в поле ввода, НЕ отправляя автоматически (требование A);
    // курсор — в конец, чтобы можно было сразу дописать руками.
    final already = _input.text;
    final merged = already.isEmpty ? text : '$already $text';
    _input.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(offset: merged.length),
    );
  }

  /// Тап по индикатору записи: остановить, но то, что уже услышано,
  /// вставить в поле (как у голосовых в мессенджере).
  void _stopVoiceTap() {
    if (!_listening) return;
    _voiceStopRequested = true;
    unawaited(VoiceControl.instance.stop());
  }

  /// Крестик: отменить совсем — текст в поле не попадает.
  void _cancelVoiceInput() {
    _voiceGen++; // результат текущего listenOnce станет неактуальным
    _voiceStopRequested = true;
    _voiceTimer?.cancel();
    _voiceTimer = null;
    if (mounted) setState(() => _listening = false);
    unawaited(VoiceControl.instance.stop());
  }

  void _send(AiChatViewModel vm, {String? forceFormat}) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final image = _pendingImage;
    setState(() => _pendingImage = null);
    vm
        .send(forceFormat == null ? text : '$text ($forceFormat)', image: image)
        .then((_) => _scrollToEnd());
    _scrollToEnd();
  }

  /// Долгое нажатие на отправку — явно попросить формат ответа, а не
  /// надеяться, что модель сама угадает его по тексту вопроса (решение
  /// пользователя, пункт 10 списка правок).
  Future<void> _pickFormat(AiChatViewModel vm) async {
    if (_input.text.trim().isEmpty) return;
    final format = await showGlassSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.show_chart),
            title: Text(tr('Ответить графиком')),
            onTap: () => Navigator.of(ctx).pop('ответь графиком'),
          ),
          ListTile(
            leading: const Icon(Icons.pie_chart_outline),
            title: Text(tr('Ответить круговой диаграммой')),
            onTap: () =>
                Navigator.of(ctx).pop('ответь круговой диаграммой (pie)'),
          ),
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: Text(tr('Ответить таблицей')),
            onTap: () => Navigator.of(ctx).pop('ответь таблицей'),
          ),
        ]),
      ),
    );
    if (format != null && mounted) _send(vm, forceFormat: format);
  }

  /// `true` — активная модель (AiSettings.chatModelChoice) точно умеет
  /// смотреть на фото: либо явно выбрана скачанная локальная модель со
  /// зрением, либо выбрана конкретная облачная (доверяем выбору — для
  /// облака заранее неизвестно, поддерживает ли модель картинки). При
  /// «Авто» — нет: ответит могла и текстовая модель, фото потеряется зря.
  Future<bool> _visionAvailable(AiSettings s) async {
    final choice = s.chatModelChoice;
    return choice != 'auto' && choice != 'local';
  }

  Future<void> _attachImage(AiSettings s) async {
    if (!await _visionAvailable(s)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              'Сначала выберите модель со зрением — кнопка ⚙ рядом с «Очистить»')),
        ));
      }
      return;
    }
    final xfile = await AppLock.external(() => ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85));
    if (xfile == null || !mounted) return;
    setState(() => _pendingImage =
        null); // сброс, пока читаем — не путать со старым превью при ошибке
    final bytes = await xfile.readAsBytes();
    if (mounted) setState(() => _pendingImage = bytes);
  }

  /// Поиск в интернете: вопрос уходит в Google Search через Gemini, ответ
  /// с источниками приходит прямо в чат. Без ключа Gemini (бесплатный, из
  /// aistudio.google.com — вставляется в настройках ИИ) предлагаем хотя бы
  /// открыть поиск в браузере телефона.
  Future<void> _searchWeb() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final vm = context.read<AiChatViewModel>();
    // Серверный поиск (Tavily) работает без своего ключа: закрытый диалог
    // показываем только когда не вошли в мессенджер и своего ключа тоже нет.
    final signedIn = ChatAuthService(context.read<AppDataStore>().db).isSignedIn;
    if (vm.service.settings.geminiKey.isEmpty && !signedIn) {
      final openBrowser = await showGlassDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Поиск в интернете')),
          content: Text(tr(
              'Чтобы ответ приходил прямо сюда, вставьте бесплатный ключ Google Gemini: Настройки → ИИ Ассистент → «Поиск в интернете». Пока можно открыть поиск в браузере.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(tr('Закрыть'))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(tr('Открыть в браузере'))),
          ],
        ),
      );
      if (openBrowser == true) {
        await launchUrl(Uri.https('www.google.com', '/search', {'q': text}),
            mode: LaunchMode.externalApplication);
      }
      return;
    }
    _input.clear();
    vm.searchWeb(text).then((_) => _scrollToEnd());
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AiChatViewModel>();

    // Отдельной страницы «Графики» больше нет.
    //
    // Внутренний PageView перехватывал горизонтальный свайп, и с чата
    // нельзя было пролистать дальше по рабочему столу — палец уходил в
    // переключение вкладок. А сами графики и так рисуются прямо в
    // сообщениях, так что вторая страница только дублировала их.
    final body = Column(
      children: [
        Expanded(
          child: widget.embedded
              ? _buildChat(vm)
              : Stack(
                  children: [
                    Positioned.fill(child: _buildChat(vm)),
                    Positioned.fill(
                      child: EdgeShade(
                          top: MediaQuery.paddingOf(context).top +
                              GlassHeader.height +
                              16),
                    ),
                  ],
                ),
        ),
        _buildInput(vm),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Ассистент'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          _ModelPickerButton(settings: vm.service.settings),
          GlassCircleButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr('Очистить разговор'),
            onTap: vm.messages.isEmpty ? null : vm.clear,
          ),
        ],
      ),
      // resizeToAvoidBottomInset выключен намеренно — Scaffold сам иногда
      // не отыгрывает обратное схлопывание после закрытия клавиатуры
      // системным жестом "назад" (а не тапом), оставляя пустой отступ
      // (та же жалоба, что уже чинили в личном/общем чате). AnimatedPadding
      // реагирует на MediaQuery сам, на каждой перестройке, и не завязан
      // на то, как именно клавиатуру закрыли.
      resizeToAvoidBottomInset: false,
      body: AnimatedPadding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        duration: const Duration(milliseconds: 100),
        child: body,
      ),
    );
  }

  Widget _buildChat(AiChatViewModel vm) {
    if (vm.messages.isEmpty) {
      // Пустой чат: быстрые запросы — в том числе графики и таблицы по тренировкам.
      final ideas = [
        tr('Построй график моих результатов по неделям'),
        tr('Сравни упражнения по кучности столбцами'),
        tr('Таблица лучших серий за последний месяц'),
        tr('Как распределены мои выстрелы по габаритам? Покажи кругом'),
      ];
      return ListView(
        padding: EdgeInsets.fromLTRB(
            16, widget.embedded ? 12 : MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 12),
        children: [
          Text(tr('Можно попросить'), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in ideas)
              ActionChip(
                avatar: const Icon(Icons.auto_graph, size: 16),
                label: Text(q),
                onPressed: vm.busy ? null : () => vm.send(q),
              ),
          ]),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
          12,
          widget.embedded
              ? 12
              : MediaQuery.paddingOf(context).top + GlassHeader.height,
          12,
          12),
      itemCount: vm.messages.length + (vm.busy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= vm.messages.length) return _ThinkingOrb(phase: vm.phase, progress: vm.phaseProgress);
        final message = vm.messages[i];
        final charts = vm.chartMessages;
        return _Bubble(
          message: message,
          // Удалить свой вопрос вместе с ответом и спросить заново.
          // Важно, что модель о нём ЗАБЫВАЕТ: иначе на повтор она
          // отвечает «как я уже писал выше» — переспрашивать смысла
          // не было бы.
          onRetry: message.fromUser && !vm.busy
              ? () => vm.retryFrom(i)
              // Ошибку ассистента повторяют тем же вопросом, которым
              // она вызвана, а не собой (у ошибки нет своего текста
              // вопроса) — решение пользователя: маленькие кнопки
              // "Удалить"/"Повторить" прямо под сообщением об ошибке,
              // а не через долгое нажатие.
              : (message.isError &&
                      !vm.busy &&
                      i > 0 &&
                      vm.messages[i - 1].fromUser)
                  ? () => vm.retryFrom(i - 1)
                  : null,
          onEdit: message.fromUser && !vm.busy
              ? () => _editMessage(context, vm, i)
              : null,
          // Удаление ответа ассистента забирает с собой и СВОЙ вопрос
          // (решение пользователя) — иначе от переписки оставался вопрос
          // без ответа. Удаление своего вопроса и так тянет всё, что
          // после него, включая ответ (см. removeFrom) — здесь только
          // добиваем обратный случай.
          onDelete: vm.busy
              ? null
              : () => vm.removeFrom(
                  !message.fromUser && i > 0 && vm.messages[i - 1].fromUser
                      ? i - 1
                      : i),
          onCreateExercise:
              (message.exercise != null && !message.exerciseCreated)
                  ? () => _createExercise(context, vm, i)
                  : null,
          onSaveNote: (message.note != null && !message.noteCreated)
              ? () => _saveNote(context, vm, i)
              : null,
          onApplyAppearance: (message.appearance != null && !message.appearanceApplied) ? () => _applyAppearance(context, vm, i) : null,
          onSendFeedback: (message.feedback != null && !message.feedbackSent)
              ? () => _sendFeedback(context, vm, i)
              : null,
          chartGallery:
              message.chart == null ? null : [for (final m in charts) m.chart!],
          chartGalleryIndex:
              message.chart == null ? 0 : charts.indexOf(message),
        );
      },
    );
  }

  /// Создаёт упражнение из блока, который предложил ассистент.
  ///
  /// Спецификация уже провалидирована белым списком в `AiService`
  /// (`_isValidExercise`) — здесь только раскладываем провалидированный
  /// JSON в вызов `store.createExercise`, который используется и
  /// обычным экраном создания упражнения.
  void _createExercise(BuildContext context, AiChatViewModel vm, int index) {
    final spec = vm.messages[index].exercise;
    if (spec == null) return;
    final store = context.read<AppDataStore>();

    // Дубль по названию и мишени не заводим, даже если ИИ его предложил:
    // жалоба пользователя — копятся одноимённые упражнения.
    final wantName = '${spec['name']}'.trim().toLowerCase();
    final dup = store.exercises.where((e) =>
        e.name.trim().toLowerCase() == wantName &&
        e.targetFaceCode == '${spec['target_face_code']}');
    if (dup.isNotEmpty) {
      vm.markExerciseCreated(index);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(tr('Упражнение «{name}» уже есть — новое не создано',
                {'name': dup.first.name}))));
      return;
    }

    final rawSeries = spec['series'];
    final series = rawSeries is List
        ? [
            for (final s in rawSeries.cast<Map>())
              SeriesSpec(
                name: '${s['name']}',
                shotCount: (s['shot_count'] as num?)?.toInt(),
                timeLimit: s['time_limit_min'] == null
                    ? null
                    : Duration(minutes: (s['time_limit_min'] as num).toInt()),
                counts: s['counts'] != false,
              ),
          ]
        : const <SeriesSpec>[];

    final gender = ExerciseGender.values.firstWhere(
      (g) => g.name == '${spec['gender'] ?? 'mixed'}',
      orElse: () => ExerciseGender.mixed,
    );

    final ex = store.createExercise(
      name: '${spec['name']}',
      targetFaceCode: '${spec['target_face_code']}',
      // У упражнения со своими сериями total_shots/series_size не несут
      // смысла — раскладка идёт по `series` (см. 7.2 ТЗ), но колонки в
      // базе NOT NULL, так что пишем сумму выстрелов серий и 1.
      totalShots: series.isNotEmpty
          ? series.fold<int>(0, (a, s) => a + (s.shotCount ?? 0))
          : (spec['total_shots'] as num).toInt(),
      seriesSize: series.isNotEmpty ? 1 : (spec['series_size'] as num).toInt(),
      gender: gender,
      series: series,
    );

    vm.markExerciseCreated(index);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(tr('Упражнение «{name}» создано', {'name': ex.name}))));
  }

  /// Применяет настройки оформления от ИИ по кнопке; в уведомлении - «Отменить».
  void _applyAppearance(BuildContext context, AiChatViewModel vm, int index) {
    final spec = vm.messages[index].appearance;
    if (spec == null) return;
    final db = context.read<AppDataStore>().db;
    final before = BackdropTint.applyAppearance(db, spec);
    vm.markAppearanceApplied(index, true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(tr('Оформление изменено')),
        action: SnackBarAction(
          label: tr('Отменить'),
          onPressed: () {
            BackdropTint.restoreAppearance(db, before);
            vm.markAppearanceApplied(index, false);
          },
        ),
      ));
  }

  /// Сохраняет заметку, которую предложил ассистент, в дневник тренера —
  /// тот же принцип показа-на-подтверждение, что и у `_createExercise`.
  void _saveNote(BuildContext context, AiChatViewModel vm, int index) {
    final spec = vm.messages[index].note;
    if (spec == null) return;
    final store = context.read<AppDataStore>();
    CoachNotesRepository(store.db).add(CoachNote(
      id: const Uuid().v4(),
      topic: '${spec['topic']}',
      content: '${spec['content']}',
      createdAt: DateTime.now(),
    ));
    vm.markNoteCreated(index);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(tr('Заметка сохранена'))));
  }

  /// Правка своего вопроса перед повторной отправкой (пункт 6 списка
  /// правок) — то же удаление-и-переспрос, что и `retryFrom`, но с
  /// изменённым текстом вместо исходного.
  Future<void> _editMessage(
      BuildContext context, AiChatViewModel vm, int index) async {
    final controller = TextEditingController(text: vm.messages[index].text);
    final text = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Изменить вопрос')),
        content: TextField(
            controller: controller, autofocus: true, minLines: 1, maxLines: 6),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(tr('Спросить заново')),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    vm.editAndRetry(index, text).then((_) => _scrollToEnd());
    _scrollToEnd();
  }

  /// Отправляет предложенный отзыв в общую базу разработчика (пункт 10
  /// списка правок) — показ-на-подтверждение, как у заметки и упражнения.
  Future<void> _sendFeedback(
      BuildContext context, AiChatViewModel vm, int index) async {
    final spec = vm.messages[index].feedback;
    if (spec == null) return;
    try {
      await FeedbackService().send('${spec['text']}');
      if (!context.mounted) return;
      vm.markFeedbackSent(index);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(tr('Отзыв отправлен, спасибо'))));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  /// Кнопки режима над строкой ввода: Fast / Normal / Think. Тот же
  /// «стеклянный» стиль, что у остальных кнопок чата (веб и Android);
  /// выбранный режим залит основным цветом. Пока идёт ответ — недоступны.
  Widget _modeSelector(AiChatViewModel vm) {
    final cs = Theme.of(context).colorScheme;
    final settings = vm.service.settings;
    final items = <(String, IconData, String, String)>[
      ('fast', Icons.bolt, 'Fast', tr('Быстрый ответ: короткий простой запрос')),
      ('normal', Icons.tune, 'Normal', tr('Точный ответ: числа пересчитываются и проверяются')),
      (
        'think',
        Icons.psychology_outlined,
        'Think',
        tr('Три помощника: план, решение, проверка — дольше, но точнее')
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Row(
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: it.$4,
                child: SizedBox(
                  height: 36,
                  child: GlassPill(
                    onTap: vm.busy
                        ? null
                        : () => setState(() => settings.chatMode = it.$1),
                    color: settings.chatMode == it.$1
                        ? cs.primary.withValues(alpha: 0.85)
                        : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(it.$2,
                            size: 18,
                            color: settings.chatMode == it.$1
                                ? cs.onPrimary
                                : cs.onSurface),
                        const SizedBox(width: 6),
                        Text(it.$3,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: settings.chatMode == it.$1
                                    ? cs.onPrimary
                                    : cs.onSurface)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInput(AiChatViewModel vm) {
    // embedded: true — экран живёт внутри PageView мишени, а не под
    // своим Scaffold, и не подвигается под клавиатуру сам (жалоба
    // пользователя: поле ввода уезжало под клавиатуру). Вне embedded
    // об этом заботится AnimatedPadding вокруг всего тела в build() —
    // дублировать отступ здесь не нужно (и на вебе `viewInsets` к тому
    // же не всегда возвращается ровно к нулю после закрытия клавиатуры).
    final keyboardInset = widget.embedded && !kIsWeb
        ? MediaQuery.of(context).viewInsets.bottom
        : 0.0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + keyboardInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingImage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(_pendingImage!,
                          width: 56, height: 56, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: -6,
                      top: -6,
                      child: GestureDetector(
                        onTap: () => setState(() => _pendingImage = null),
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: Theme.of(context).colorScheme.error,
                          child: const Icon(Icons.close,
                              size: 13, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            _modeSelector(vm),
            // Пока идёт распознавание — вместо поля ввода панель записи
            // (просьба владельца 23.11, п. 2). Вложение и режимы выше
            // остаются на месте и не подменяются (требование E).
            if (_listening)
              _buildVoicePanel(vm)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                // Бесплатная авто-модель не читает фото, а без ключа Gemini
                // поиск в чате не работает — такие кнопки только путают
                // (решение пользователя, пункт 8 второго списка правок).
                if (vm.service.settings.chatModelChoice != 'auto') ...[
                  GlassCircleButton(
                    size: 50,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    tooltip: tr('Приложить фото (нужна модель со зрением)'),
                    onTap: vm.busy
                        ? null
                        : () => _attachImage(vm.service.settings),
                  ),
                  const SizedBox(width: 8),
                ],
                if (vm.service.settings.geminiKey.isNotEmpty) ...[
                  GlassCircleButton(
                    size: 50,
                    icon: const Icon(Icons.travel_explore_outlined),
                    tooltip: tr('Найти в интернете'),
                    onTap: vm.busy ? null : _searchWeb,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: GlassPill(
                    radius: 25,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      // Enter — перевод строки, а не отправка (решение
                      // пользователя): сообщение уходит только по кнопке.
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: tr('Что вас интересует?'),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Микрофон для голосового ввода (просьба владельца 23.11,
                // п. 2): распознанная речь попадает в поле ввода, а не
                // отправляется сама. Доступен и пока идёт ответ — текст
                // просто наберётся в поле.
                GlassCircleButton(
                  size: 50,
                  tooltip: tr('Голосовой ввод'),
                  onTap: _listening ? null : _startVoiceInput,
                  icon: Icon(Icons.mic_none,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onLongPress: vm.busy ? null : () => _pickFormat(vm),
                  child: GlassCircleButton(
                    size: 50,
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.85),
                    onTap: vm.busy ? null : () => _send(vm),
                    icon: Icon(Icons.send,
                        color: Theme.of(context).colorScheme.onPrimary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Панель записи вместо строки ввода: индикатор (вращающийся квадрат,
  /// столбики, таймер) + кнопка отмены. Тап по индикатору — остановить
  /// и вставить услышанное, крестик — отменить совсем (требование A).
  Widget _buildVoicePanel(AiChatViewModel vm) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: GlassPill(
            radius: 25,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 50,
              child: Row(
                children: [
                  VoiceRecordingIndicator(
                    recording: true,
                    elapsed: _voiceElapsed,
                    color: cs.primary,
                    onTap: _stopVoiceTap,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('Слушаю…'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GlassCircleButton(
          size: 50,
          tooltip: tr('Отмена'),
          onTap: _cancelVoiceInput,
          icon: Icon(Icons.close, color: cs.onSurface),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final AiMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// `null`, если в сообщении нет предложенного упражнения или оно уже
  /// создано — тогда карточка показывает отметку без кнопки.
  final VoidCallback? onCreateExercise;

  /// `null`, если в сообщении нет предложенной заметки в дневник или она
  /// уже сохранена.
  final VoidCallback? onSaveNote;

  /// `null`, если в сообщении нет предложенного отзыва или он уже
  /// отправлен.
  final VoidCallback? onSendFeedback;

  /// `null`, если в сообщении нет настроек оформления или они уже применены.
  final VoidCallback? onApplyAppearance;

  /// Все графики разговора и позиция графика ЭТОГО сообщения среди них —
  /// для листания в полноэкранном просмотре (`ChartGalleryScreen`).
  /// `null`/пусто, если в сообщении графика нет вовсе.
  final List<Map<String, dynamic>>? chartGallery;
  final int chartGalleryIndex;

  const _Bubble({
    required this.message,
    this.onRetry,
    this.onEdit,
    this.onDelete,
    this.onCreateExercise,
    this.onSaveNote,
    this.onSendFeedback,
    this.onApplyAppearance,
    this.chartGallery,
    this.chartGalleryIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = message.fromUser;
    // Оформление как в мессенджере — те же цвета, скругление и тень пузырей.
    final prefs = ChatPreferences(context.read<AppDataStore>().db);
    final bg = message.isError
        ? cs.errorContainer
        : (mine ? prefs.mineBubbleColor : prefs.otherBubbleColor);
    final fg = message.isError
        ? cs.onErrorContainer
        : (mine ? prefs.mineTextColor : prefs.otherTextColor);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: (onRetry == null && onEdit == null && onDelete == null)
            ? null
            : () => _showActions(context),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(prefs.bubbleRadius),
            gradient: bubbleGradient(bg),
            boxShadow: prefs.shadowEnabled
                ? [
                    BoxShadow(
                        color: Colors.black
                            .withValues(alpha: prefs.shadowIntensity),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.reasoning != null) ...[
                _ReasoningBlock(text: message.reasoning!, color: fg),
                const SizedBox(height: 8),
              ],
              if (message.imageBytes != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(prefs.bubbleRadius * 0.6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: Image.memory(message.imageBytes!, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SelectableText(message.text,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              if (message.chart != null) ...[
                const SizedBox(height: 8),
                AiChartView(
                  spec: message.chart!,
                  gallery: chartGallery,
                  galleryIndex: chartGalleryIndex,
                ),
              ],
              if (message.exercise != null) ...[
                const SizedBox(height: 8),
                _ExerciseProposalCard(
                  spec: message.exercise!,
                  created: message.exerciseCreated,
                  onCreate: onCreateExercise,
                ),
              ],
              if (message.appearance != null) ...[
                const SizedBox(height: 8),
                _AppearanceProposalCard(spec: message.appearance!, applied: message.appearanceApplied, onApply: onApplyAppearance),
              ],
              if (message.note != null) ...[
                const SizedBox(height: 8),
                _NoteProposalCard(
                  spec: message.note!,
                  created: message.noteCreated,
                  onSave: onSaveNote,
                ),
              ],
              if (message.feedback != null) ...[
                const SizedBox(height: 8),
                _FeedbackProposalCard(
                  spec: message.feedback!,
                  sent: message.feedbackSent,
                  onSend: onSendFeedback,
                ),
              ],
              if (message.sources.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  tr('Источники: {p}', {'p': message.sources.join(', ')}),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: fg.withValues(alpha: 0.75)),
                ),
              ],
              if (message.model != null) ...[
                const SizedBox(height: 4),
                Text(
                  message.model!,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: fg.withValues(alpha: 0.6)),
                ),
              ],
              // Маленькие кнопки прямо под сообщением об ошибке (решение
              // пользователя) — не прятать за долгим нажатием то, что
              // нужно сразу после сбоя ответа.
              if (message.isError && (onDelete != null || onRetry != null)) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onRetry != null)
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(tr('Повторить')),
                        style: TextButton.styleFrom(
                            foregroundColor: fg,
                            visualDensity: VisualDensity.compact),
                      ),
                    if (onDelete != null)
                      TextButton.icon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: Text(tr('Удалить')),
                        style: TextButton.styleFrom(
                            foregroundColor: fg,
                            visualDensity: VisualDensity.compact),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showGlassSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRetry != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(tr('Спросить заново')),
                subtitle: Text(tr('Ассистент забудет прежний вопрос и ответ')),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onRetry!();
                },
              ),
            if (onEdit != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(tr('Изменить')),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onEdit!();
                },
              ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(tr('Удалить')),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onDelete!();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Карточка предложенного ассистентом упражнения — показ результата на
/// подтверждение, а не тихое создание: пользователь видит, что именно
/// заведётся, прежде чем это попадёт в список упражнений.
/// Карточка настроек оформления от ассистента: что изменится и кнопка «Применить» (потом можно отменить).
class _AppearanceProposalCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final bool applied;
  final VoidCallback? onApply;
  const _AppearanceProposalCard({required this.spec, required this.applied, required this.onApply});

  static const _names = {
    'mode': 'Режим оттенка',
    'hue': 'Оттенок',
    'sat': 'Насыщенность',
    'blur': 'Размытость',
    'transparency': 'Прозрачность маски',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.palette_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Text(tr('Изменить оформление'), style: theme.textTheme.titleSmall),
        ]),
        const SizedBox(height: 4),
        for (final e in spec.entries)
          Text('· ${tr(_names[e.key] ?? e.key)}: ${e.value is num && e.key != 'hue' ? '${((e.value as num) * 100).round()}%' : e.value}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        if (applied)
          Row(children: [
            Icon(Icons.check_circle, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Text(tr('Применено'), style: theme.textTheme.bodySmall?.copyWith(color: cs.primary)),
          ])
        else
          Raised3DButton(dense: true, icon: Icons.palette_outlined, label: tr('Применить'), baseColor: cs.primary, onTap: onApply),
      ]),
    );
  }
}

class _ExerciseProposalCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final bool created;
  final VoidCallback? onCreate;

  const _ExerciseProposalCard(
      {required this.spec, required this.created, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final face = TargetFace.byCode('${spec['target_face_code']}');
    final rawSeries = spec['series'];
    final seriesList = rawSeries is List ? rawSeries.cast<Map>() : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_add, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child:
                    Text('${spec['name']}', style: theme.textTheme.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(face.name, style: theme.textTheme.bodySmall),
          if (seriesList != null)
            for (final s in seriesList)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '· ${s['name']}'
                  '${s['shot_count'] != null ? ' — ${s['shot_count']} выстр.' : ''}'
                  '${s['time_limit_min'] != null ? ' — ${s['time_limit_min']} мин' : ''}'
                  '${s['counts'] == false ? ' (без зачёта)' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              )
          else
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                tr('{p} выстрелов по {p2}',
                    {'p': spec['total_shots'], 'p2': spec['series_size']}),
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          if (created)
            Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(tr('Создано'),
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.primary)),
              ],
            )
          else
            Raised3DButton(
              dense: true,
              icon: Icons.add,
              label: tr('Создать упражнение'),
              baseColor: cs.primary,
              onTap: onCreate,
            ),
        ],
      ),
    );
  }
}

/// Карточка предложенной ассистентом заметки в дневник тренера — тот же
/// принцип, что у `_ExerciseProposalCard`: показ на подтверждение.
class _NoteProposalCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final bool created;
  final VoidCallback? onSave;

  const _NoteProposalCard(
      {required this.spec, required this.created, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                  child: Text('${spec['topic']}',
                      style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${spec['content']}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          if (created)
            Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(tr('Сохранено'),
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.primary)),
              ],
            )
          else
            Raised3DButton(
              dense: true,
              icon: Icons.add,
              label: tr('Сохранить в заметки'),
              baseColor: cs.primary,
              onTap: onSave,
            ),
        ],
      ),
    );
  }
}

/// Карточка предложенного отзыва об приложении — тот же принцип, что у
/// `_NoteProposalCard`/`_ExerciseProposalCard`: показ на подтверждение.
class _FeedbackProposalCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final bool sent;
  final VoidCallback? onSend;

  const _FeedbackProposalCard(
      {required this.spec, required this.sent, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.rate_review_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text(tr('Отзыв о приложении'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${spec['text']}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          if (sent)
            Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(tr('Отправлено'),
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: cs.primary)),
              ],
            )
          else
            Raised3DButton(
              dense: true,
              icon: Icons.send,
              label: tr('Отправить отзыв'),
              baseColor: cs.primary,
              onTap: onSend,
            ),
        ],
      ),
    );
  }
}

/// Пузырь «ассистент работает»: «думающая сфера» на CustomPainter.
///
/// Референс — промпт владельца 23.11 (React-компонент
/// ai-thinking-orb-and-input.tsx): пока модель отвечает, на месте ответа
/// видна морфящая сфера — она «собирается» в шар, шар пульсирует и
/// вращается (кольца-дуги, мелкие частицы по орбитам, радиальные
/// градиенты), фазы подписаны («Thinking» → «Searching» → «Analyzing» →
/// «Composing»), затем сфера «раскрывается» в карточку ответа.
/// Сюда переносится только сама сфера: «раскрытие» в карточку делает
/// ListView, подменяющий пузырь готовым сообщением, — морфить
/// незачем, иначе лента дёргается.
class _ThinkingOrb extends StatefulWidget {
  final String phase;

  /// «2/3» в режиме Think — номер подхода.
  final String progress;
  const _ThinkingOrb({required this.phase, this.progress = ''});

  @override
  State<_ThinkingOrb> createState() => _ThinkingOrbState();
}

class _ThinkingOrbState extends State<_ThinkingOrb>
    with SingleTickerProviderStateMixin {
  /// Размер сферы в пузыре: 104 px — посередине диапазона 96–120 из
  /// задачи; фиксированный, чтобы пузырь не менял размер и не дёргал
  /// ленту (требование «компактно, не дёргает ленту»).
  static const double _orbD = 104;

  /// Цикл вращения сферы: 2400 мс попадает в заданный диапазон
  /// 2000–2600 мс и задан в промпте владельца как «спокойный» темп.
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));

  /// «Уменьшить движение» в системе: сфера замирает статичным кадром,
  /// контроллер не тикает (требование D — как у VoiceRecordingIndicator).
  bool _still = false;

  /// Счётчик секунд для смены фаз: Stopwatch не зависит от повторов
  /// контроллера (repeat сбрасывает value, а фазы должны идти подряд) —
  /// 1 фаза ≈ 1.2 с, как в промпте владельца (labelLoop 1150 мс).
  final Stopwatch _clock = Stopwatch()..start();

  // Запуск/остановка здесь, а не в инициализаторе поля: нужно сначала
  // посмотреть disableAnimations, иначе при включённом ограничении
  // анимация успевает тикнуть вхолостую.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_still) {
      if (_c.isAnimating) _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _clock.stop();
    _c.dispose();
    super.dispose();
  }

  /// Подпись фазы под сферой. Четыре строки из промпта владельца
  /// (Thinking/Searching/Analyzing/Composing) сменяются по внутреннему
  /// счётчику секунд. Реальный шаг пайплайна из AiChatViewModel показываем,
  /// когда он «дальше» декоративной ротации — сформировался ответ или
  /// идёт проверка: правда важнее анимации.
  String _phaseLabel() {
    if (widget.phase == 'Формулирую ответ') return tr('Собираю ответ…');
    if (widget.phase == 'Проверяю') return tr('Анализирую…');
    const phases = ['Думаю…', 'Ищу…', 'Анализирую…', 'Собираю ответ…'];
    final i = (_clock.elapsedMilliseconds ~/ 1200) % phases.length;
    final label = tr(phases[i]);
    return widget.progress.isEmpty ? label : '$label ${widget.progress}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Появление: сфера «собирается» — лёгкий разгон масштаба с
            // мягким отскоком (Curves.easeOutBack), отсылка к фазам
            // launch/assemble промпта владельца. Один раз при входе, без
            // повторов — лента не дёргается.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              builder: (context, v, child) => Opacity(
                opacity: v.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
              ),
              child: SizedBox(
                width: _orbD,
                height: _orbD,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, __) => CustomPaint(
                    painter: _OrbPainter(
                      t: _still ? 0.3 : _c.value,
                      primary: cs.primary,
                      tertiary: cs.tertiary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Смена фаз с коротким кроссфейдом — как «swapLabel» в промпте.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                _phaseLabel(),
                key: ValueKey(_phaseLabel()),
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Рисовальщик сферы: радиальные градиенты из colorScheme.primary/tertiary,
/// внутреннее свечение, вращающиеся дуги-кольца и частицы по орбитам.
///
/// Все позиции частиц детерминированы по индексу (золотой угол,
/// const goldenAngle ≈ 2.39996) — никакого Random на кадр: иначе на
/// CanvasKit/в тестах каждый кадр рисуется по-новому и включается
/// перерисовка впустую.
class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.primary, required this.tertiary});

  /// Фаза цикла [0..1] от AnimationController (_ThinkingOrb).
  final double t;
  final Color primary;
  final Color tertiary;

  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Мягкое ореольное свечение вокруг сферы — слой «halo» из промпта.
    // Тонкий alpha у primary на тёмном фоне даёт глубину как у стекла.
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(alpha: 0.30),
          primary.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: size.width / 2));
    canvas.drawCircle(center, size.width / 2, glowPaint);

    // Пульс радиуса: ±4 % — спокойное «дыхание» (аналог orb.pop в промпте).
    final r = size.width * 0.31 * (1 + 0.04 * math.sin(t * _tau));

    // Сфера: радиальный градиент со смещённым фокусом — свет сверху-слева,
    // к краю холоднее и темнее (tertiary). Промпт рисует то же самое
    // светло-зелёной палитрой, здесь — цвета темы приложения.
    final light = center - Offset(r * 0.35, r * 0.4);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(primary, Colors.white, 0.7)!,
            primary,
            Color.lerp(tertiary, primary, 0.25)!,
          ],
          stops: const [0.0, 0.55, 1.0],
          // Фокус — Alignment в нормированных координатах круга-шейдера:
          // свет сверху-слева (как светлая точка в промпте). Радиус фокуса
          // — доля радиуса градиента, чтобы переход был мягким.
          focal: const Alignment(-0.35, -0.4),
          focalRadius: 0.05,
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Внутреннее свечение в точке света (поток «sphere glow» из промпта).
    canvas.drawCircle(
      light,
      r * 0.4,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.45),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: light, radius: r * 0.4)),
    );
    // Тонкая кромка по краю шара отделяет его от ореола.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.10),
    );

    // Три кольца-дуги с прозрачностью: разный радиус, скорость и высота
    // эллипса создают ощущение «3D-вращения», как у кольца-орбиты в промпте.
    _ring(canvas, center, r * 1.22,
        start: t * _tau,
        sweep: _tau * 0.25,
        width: 1.6,
        color: primary.withValues(alpha: 0.45));
    _ring(canvas, center, r * 1.05,
        start: -t * _tau * 0.6 + 2.1,
        sweep: _tau * 0.25,
        width: 1.2,
        color: Colors.white.withValues(alpha: 0.18));
    // Среднее кольцо — эллипс: рисуем в сжатой системе координат.
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(1.0, 0.42);
    _ring(canvas, Offset.zero, r * 1.5,
        start: -t * _tau * 0.7 + 1.0,
        sweep: _tau * 0.25,
        width: 1.4,
        color: tertiary.withValues(alpha: 0.5));
    canvas.restore();

    // Частицы по орбитам — 16 точек (задача: 12–20). Детерминированные
    // позиции по индексу: золотой угол по «меридиану», три «пояса» с
    // разными наклоном и скоростью; глубина — по синусу фазы: она
    // управляет только яркостью и размером точки (дальние — тусклее и
    // мельче), рисуем всё поверх шара, физического перекрытия нет.
    const count = 16;
    for (var i = 0; i < count; i++) {
      final band = i % 3;
      final phi0 = i * 2.39996;
      final orbit = r * (0.35 + 0.18 * (band / 2));
      // Распределение скоростей по остатку индекса — тоже детерминизм.
      final speed = (band == 0 ? 1.0 : (band == 1 ? -0.8 : 0.6)) *
          (0.55 + 0.1 * (i % 5));
      final phi = phi0 + t * _tau * speed;
      final depth = (math.sin(phi) + 1) / 2; // 0 — сзади, 1 — спереди
      final tilt = band == 1 ? 0.35 : 0.45;
      final p = Offset(
        center.dx + math.cos(phi) * orbit,
        center.dy + math.sin(phi) * orbit * tilt,
      );
      // Дальние точки тусклее и мельче — простая имитация глубины.
      final dotColor = Color.lerp(tertiary, Colors.white, 0.2 + 0.6 * depth)!
          .withValues(alpha: 0.15 + 0.5 * depth);
      canvas.drawCircle(p, 1.1 + 1.0 * depth, Paint()..color = dotColor);
    }
  }

  /// Одна дуга-кольцо: круг на радиусе [radius] от угла [start]
  /// длиной [sweep], только обводка.
  void _ring(
    Canvas canvas,
    Offset center,
    double radius, {
    required double start,
    required double sweep,
    required double width,
    required Color color,
  }) {
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) =>
      // Кадр зависит только от фазы контроллера и цветов темы: если и то и
      // то не менялось — рисуем заново впустую, CanvasKit и так нагружен.
      oldDelegate.t != t ||
      oldDelegate.primary != primary ||
      oldDelegate.tertiary != tertiary;
}

/// Свёрнутый блок «Завершено размышление».
///
/// Рассуждения модели не выбрасываются, а прячутся под раскрывающийся
/// заголовок: сам ответ остаётся читаемым, но при желании видно, на чём
/// модель его построила. Именно так эту проблему решают взрослые чаты —
/// и это честнее, чем молча резать текст.
class _ReasoningBlock extends StatefulWidget {
  final String text;
  final Color color;

  const _ReasoningBlock({required this.text, required this.color});

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = widget.color.withValues(alpha: 0.7);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lightbulb_outline, size: 15, color: muted),
                const SizedBox(width: 6),
                Text(
                  tr('Завершено размышление'),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
                Icon(_open ? Icons.expand_more : Icons.chevron_right,
                    size: 18, color: muted),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: muted, width: 2)),
            ),
            child: SelectableText(
              widget.text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: muted, height: 1.35),
            ),
          ),
        ],
      ],
    );
  }
}
