import '../widgets/glass_route.dart';
import 'dart:async';
import '../widgets/app_loader.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../finals/announcer.dart';
import '../finals/bot.dart';
import '../finals/final_engine.dart';
import '../finals/final_run.dart';
import '../finals/finals_net.dart';
import '../finals/finals_repository.dart';
import '../finals/finals_session_service.dart';
import '../i18n/i18n.dart';
import '../models/chat_contact.dart';
import '../models/target_face.dart';
import '../services/chat_auth_service.dart';
import '../services/chat_messages_repository.dart';
import '../services/chat_sync_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import 'final_run_screen.dart';

String _bannerOf(FinalsSnapshot s) {
  switch (s.phase) {
    case 'sighting':
      return tr('Подготовка и пристрелка');
    case 'loading':
      return tr('Ждём команду');
    case 'grace':
      return tr('Стоп! Отметьте выстрелы');
    case 'finished':
      return tr('Финал окончен');
    default:
      if (s.round == 'shootoff') return tr('Перестрелка');
      if (s.round == 'open') return tr('С колена и лёжа: 20 выстрелов');
      final n = s.round.split(':').last;
      return s.round.startsWith('series')
          ? tr('Серия {n}', {'n': n})
          : tr('Выстрел {n}', {'n': n});
  }
}

String _timeOf(FinalsSnapshot s) {
  final v = s.phase == 'shooting'
      ? (s.roundLimit - s.roundSeconds).clamp(0, 9999)
      : s.secondsLeft;
  return '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
}

String _nextLabel(String phase) => switch (phase) {
      'sighting' => tr('Заряжай'),
      'loading' => tr('Старт'),
      'shooting' => tr('Стоп'),
      'grace' => tr('Далее'),
      _ => '',
    };

/// Общий экран финала для всех ролей: хозяин (состояние из своего контроллера)
/// и гости (состояние по сети). Спортсмен видит свою мишень, тренер и помощник
/// — список всех людей-участников и вводят выстрелы за любого.
class FinalRoomView extends StatelessWidget {
  final FinalsSnapshot snapshot;
  final FinalsRole role;
  final String? ownId; // спортсмен: его id в финале
  final void Function(String who, Offset mm) onShoot;
  final void Function(String who) onUndo;
  final VoidCallback? onNext; // команды: заряжай / старт / стоп
  final VoidCallback? onPause;
  final VoidCallback? onLeave;

  /// Нет связи: показываем последнее состояние и предупреждение.
  final bool offline;

  const FinalRoomView({
    super.key,
    required this.snapshot,
    required this.role,
    required this.onShoot,
    required this.onUndo,
    this.ownId,
    this.onNext,
    this.onPause,
    this.onLeave,
    this.offline = false,
  });

  Future<void> _openInput(
      BuildContext context, Map<String, dynamic> row) async {
    await showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _InputSheet(
          snapshot: snapshot,
          who: '${row['id']}',
          name: '${row['name']}',
          onShoot: onShoot,
          onUndo: onUndo),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = snapshot;
    final rows = s.rows;
    final own = ownId == null ? null : s.row(ownId!);
    final inputRows = [
      for (final r in rows)
        if (r['human'] == true) r
    ];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Row(children: [
          Expanded(
              child: Text(_bannerOf(s),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis)),
          Text(_timeOf(s),
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          if (onPause != null)
            IconButton(
                icon: Icon(s.paused ? Icons.play_arrow : Icons.pause),
                onPressed: onPause),
          if (onLeave != null)
            IconButton(
                tooltip: tr('Покинуть финал'),
                icon: const Icon(Icons.logout),
                onPressed: onLeave),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12,
            MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 12, 24),
        children: [
          if (offline)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.wifi_off, color: cs.onErrorContainer, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(tr('Нет связи — подключаемся снова'),
                        style: TextStyle(color: cs.onErrorContainer))),
              ]),
            ),
          if (onNext != null && s.phase != 'finished')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: onNext,
                  child: Text(_nextLabel(s.phase),
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          if (s.paused)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('Пауза'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium),
            ),
          // Спортсмен: своя мишень сразу.
          if (role == FinalsRole.athlete && own != null) ...[
            Text('${own['name']}',
                textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.40,
              child: ShotPad(
                face: TargetFace.byCode(s.face),
                marks: [
                  for (final m in (own['staged'] as List? ?? const []))
                    Offset((m[0] as num).toDouble(), (m[1] as num).toDouble())
                ],
                enabled: own['can'] == true &&
                    !s.paused &&
                    (own['staged'] as List).length < s.shotsPerShooter,
                onHold: (_) {},
                onShot: (mm) => onShoot('$ownId', mm),
              ),
            ),
            Row(children: [
              Expanded(
                child: Text(
                  own['can'] == true
                      ? tr('Осталось выстрелов: {n}', {
                          'n':
                              s.shotsPerShooter - (own['staged'] as List).length
                        })
                      : (own['active'] == true
                          ? tr('Ждите команды')
                          : tr('Вы выбыли')),
                ),
              ),
              TextButton.icon(
                onPressed: ((own['staged'] as List?) ?? const []).isEmpty
                    ? null
                    : () => onUndo('$ownId'),
                icon: const Icon(Icons.undo),
                label: Text(tr('Назад')),
              ),
            ]),
            const SizedBox(height: 8),
          ],
          // Таблица (у тренера и помощника — с кнопкой ввода).
          for (var i = 0; i < rows.length; i++)
            Opacity(
              opacity: rows[i]['active'] == true ? 1 : 0.5,
              child: InkWell(
                // Жюри: нажали на спортсмена в списке — открылась его мишень для ввода выстрелов.
                borderRadius: BorderRadius.circular(12),
                onTap:
                    (role == FinalsRole.coach || role == FinalsRole.helper) &&
                            rows[i]['human'] == true &&
                            rows[i]['active'] == true
                        ? () => _openInput(context, rows[i])
                        : null,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: rows[i]['id'] == ownId
                        ? cs.primary.withValues(alpha: 0.16)
                        : cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    SizedBox(
                        width: 26,
                        child: Text('${rows[i]['place'] ?? (i + 1)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800))),
                    Expanded(
                        child: Text('${rows[i]['name']}',
                            overflow: TextOverflow.ellipsis)),
                    Text(
                        ((rows[i]['shots'] as List).isEmpty)
                            ? ''
                            : '${tr('ср')} ${(rows[i]['avg'] as num).toStringAsFixed(2)}  ',
                        style: theme.textTheme.bodySmall),
                    Text((rows[i]['total'] as num).toStringAsFixed(1),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    if ((role == FinalsRole.coach ||
                            role == FinalsRole.helper) &&
                        rows[i]['human'] == true &&
                        rows[i]['active'] == true)
                      IconButton(
                        tooltip: tr('Ввести выстрел'),
                        icon: Icon(Icons.gps_fixed,
                            color: rows[i]['can'] == true ? cs.primary : null),
                        onPressed: () => _openInput(context, rows[i]),
                      ),
                  ]),
                ),
              ),
            ),
          if ((role == FinalsRole.coach || role == FinalsRole.helper) &&
              inputRows.isEmpty)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(tr('Нет участников-людей'))),
        ],
      ),
    );
  }
}

/// Нижнее окно ввода выстрела за выбранного участника (тренер, помощник).
class _InputSheet extends StatefulWidget {
  final FinalsSnapshot snapshot;
  final String who;
  final String name;
  final void Function(String who, Offset mm) onShoot;
  final void Function(String who) onUndo;
  const _InputSheet(
      {required this.snapshot,
      required this.who,
      required this.name,
      required this.onShoot,
      required this.onUndo});

  @override
  State<_InputSheet> createState() => _InputSheetState();
}

class _InputSheetState extends State<_InputSheet> {
  // Локальная отметка до следующего состояния от хозяина.
  final List<Offset> _local = [];

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final row = s.row(widget.who);
    final staged = [
      for (final m in (row?['staged'] as List? ?? const []))
        Offset((m[0] as num).toDouble(), (m[1] as num).toDouble())
    ];
    final marks = staged.length >= _local.length ? staged : _local;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: Text(widget.name,
                      style: Theme.of(context).textTheme.titleMedium)),
              Text(tr('Выстрелов: {n}/{m}',
                  {'n': marks.length, 'm': s.shotsPerShooter})),
              TextButton.icon(
                onPressed: marks.isEmpty
                    ? null
                    : () {
                        widget.onUndo(widget.who);
                        setState(() {
                          if (_local.isNotEmpty) _local.removeLast();
                        });
                      },
                icon: const Icon(Icons.undo),
                label: Text(tr('Назад')),
              ),
              IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ShotPad(
                face: TargetFace.byCode(s.face),
                marks: marks,
                enabled: row?['can'] == true &&
                    !s.paused &&
                    marks.length < s.shotsPerShooter,
                onHold: (_) {},
                onShot: (mm) {
                  widget.onShoot(widget.who, mm);
                  setState(() => _local.add(mm));
                },
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Лобби тренера: состав, приглашения, начало финала.

class _Pick {
  final ChatContact contact;
  FinalsRole role;
  _Pick(this.contact, this.role);
  String get targetId => 'u_${contact.id}';
}

class FinalsLobbyScreen extends StatefulWidget {
  final FinalFormat format;
  const FinalsLobbyScreen({super.key, required this.format});

  @override
  State<FinalsLobbyScreen> createState() => _FinalsLobbyScreenState();
}

class _FinalsLobbyScreenState extends State<FinalsLobbyScreen> {
  late final AppDataStore _store = context.read<AppDataStore>();
  late final ChatAuthService _auth = ChatAuthService(_store.db);
  late final FinalsSessionService _svc = FinalsSessionService(_auth);
  final List<_Pick> _picks = [];
  String? _sessionId;
  List<FinalsMember> _members = [];
  Timer? _poll;
  bool _busy = false;
  bool _hostShoots =
      false; // ведущий сам стреляет (финал спортсменов без тренера)

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _addPerson() async {
    final contacts = [
      for (final c in ChatMessagesRepository(_store.db).listContacts())
        if (!c.isGroup && !_picks.any((p) => p.contact.id == c.id)) c
    ];
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Нет контактов мессенджера для приглашения'))));
      return;
    }
    final c = await showGlassSheet<ChatContact>(
      context: context,
      builder: (ctx) => ListView(children: [
        for (final c in contacts)
          ListTile(title: Text(c.nickname), onTap: () => Navigator.pop(ctx, c))
      ]),
    );
    if (c == null || !mounted) return;
    final role = await showGlassDialog<FinalsRole>(
      context: context,
      builder: (ctx) => SimpleDialog(title: Text(c.nickname), children: [
        SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, FinalsRole.athlete),
            child: Text(tr('Участник'))),
        // Жюри: объявляют команды и вносят результаты, права равные; кто чем занят —
        // договариваются сами (отдельных ролей внутри жюри нет).
        SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, FinalsRole.coach),
            child: Text(tr('Жюри (команды и ввод результатов)'))),
      ]),
    );
    if (role != null) setState(() => _picks.add(_Pick(c, role)));
  }

  Future<void> _createAndInvite() async {
    if (_busy) return;
    setState(() => _busy = true);
    final sid = await _svc.create(widget.format.id);
    if (sid == null) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
                'Не удалось создать финал. Мы уже получили отчёт — попробуйте позже'))));
      }
      return;
    }
    for (final p in _picks) {
      await _svc.invite(sid,
          userId: p.contact.id,
          role: p.role,
          targetId: p.role == FinalsRole.athlete ? p.targetId : null,
          name: p.contact.nickname);
      // Приглашение дублируем сообщением в мессенджере — оно приходит push-уведомлением.
      try {
        await ChatSyncService(_auth, ChatMessagesRepository(_store.db)).send(
            p.contact.id,
            tr('Приглашаю в финал! Откройте мессенджер или вкладку «Финалы» (модуль «Финалы» должен быть включён в настройках) и примите приглашение.'));
      } catch (_) {}
    }
    _sessionId = sid;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final m = await _svc.members(sid);
      if (mounted) setState(() => _members = m);
    });
    if (mounted) setState(() => _busy = false);
  }

  void _start() {
    final sid = _sessionId!;
    final accepted = [
      for (final m in _members)
        if (m.status == 'accepted') m
    ];
    final guests = [
      for (final m in accepted)
        if (m.role == FinalsRole.athlete) m
    ];
    final hostId = _hostShoots ? 'u_${_auth.userId}' : null;
    // Ведущий, если стреляет, — первый участник.
    final athletes = [
      if (hostId != null)
        FinalsMember(sid, _auth.userId, FinalsRole.athlete, hostId,
            _auth.nickname, 'accepted'),
      ...guests,
    ];
    if (athletes.isEmpty) return;
    final f = widget.format;
    final face = TargetFace.byCode(f.faceCode);
    final fallback = switch (f.faceCode) {
      'pistol_10m' => const ShotStats(0, 0, 9.0, 9.0, 0),
      'rifle_50m' => const ShotStats(0, 0, 6.0, 6.0, 0),
      _ => const ShotStats(0, 0, 3.5, 3.5, 0),
    };
    const names = [
      'Бывалый',
      'Татошка',
      'Кость',
      'Я в свое время тоже стрельбой занимался',
      'Рыцарь',
      'Сахарок',
      'Усталый'
    ];
    final rng = math.Random();
    final competitors = [
      for (final a in athletes) FinalCompetitor(a.targetId!, a.name),
      for (var i = 0; i < f.finalists - athletes.length; i++)
        FinalCompetitor('b$i', '${names[i % names.length]} (Bot)'),
    ];
    final botCount = f.finalists - athletes.length;
    final levels = [
      BotDifficulty.easy,
      BotDifficulty.medium,
      BotDifficulty.medium,
      BotDifficulty.hard,
      BotDifficulty.hard,
      BotDifficulty.unpredictable,
      BotDifficulty.easy
    ];
    final controller = FinalRunController(
      format: f,
      face: face,
      engine: FinalEngine(f, competitors.take(f.finalists).toList()),
      userId: athletes.first.targetId!,
      otherHumans: {for (final a in athletes.skip(1)) a.targetId!},
      bots: {
        for (var i = 0; i < botCount; i++)
          'b$i': BotShooter(fallback, levels[i % levels.length], face,
              math.Random(rng.nextInt(1 << 30))),
      },
      rng: rng,
      manual: true,
    );
    _poll?.cancel();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FinalHostScreen(
          controller: controller,
          sessionId: sid,
          service: _svc,
          store: _store,
          members: _members,
          hostCompetitorId: hostId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started = _sessionId != null;
    final accepted = _members
        .where((m) => m.status == 'accepted' && m.role == FinalsRole.athlete)
        .length;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
          title: Text(tr('Финал с участниками'),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600))),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + GlassHeader.height + 8,
                16,
                16),
            children: [
              Text(tr(widget.format.nameKey),
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                  tr('Вы ведёте финал: подаёте команды кнопкой «Далее», остальных финалистов до 8 заменят боты.'),
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Я тоже стреляю')),
                subtitle: Text(tr(
                    'Финал спортсменов онлайн без тренера: вы ведёте команды и стреляете сами')),
                value: _hostShoots,
                onChanged:
                    started ? null : (v) => setState(() => _hostShoots = v),
              ),
              Text(tr('Участники'), style: theme.textTheme.titleSmall),
              for (final p in _picks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.contact.nickname),
                  subtitle: Text(switch (p.role) {
                    FinalsRole.athlete => tr('Участник'),
                    FinalsRole.helper => tr('Жюри'),
                    FinalsRole.coach => tr('Жюри'),
                  }),
                  trailing: started
                      ? Text(_members
                          .where((m) => m.userId == p.contact.id)
                          .map((m) => switch (m.status) {
                                'accepted' => tr('в сети'),
                                'declined' => tr('отказ'),
                                _ => tr('ждём'),
                              })
                          .join(', '))
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _picks.remove(p))),
                ),
              if (!started)
                OutlinedButton.icon(
                    onPressed: _addPerson,
                    icon: const Icon(Icons.person_add_alt),
                    label: Text(tr('Пригласить'))),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : started
                        ? (accepted > 0 || _hostShoots ? _start : null)
                        : (_hostShoots ||
                                _picks.any((p) => p.role == FinalsRole.athlete)
                            ? _createAndInvite
                            : null),
                child: Text(started
                    ? tr('Начать финал ({n} принял)', {'n': accepted})
                    : tr('Разослать приглашения')),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Телефон «хозяина»: ведёт финал, раздаёт состояние, применяет выстрелы.

class FinalHostScreen extends StatefulWidget {
  final FinalRunController controller;
  final String sessionId;
  final FinalsSessionService service;
  final AppDataStore store;
  final List<FinalsMember> members;

  /// Если ведущий сам стреляет — его id участника; иначе `null` (он только ведёт).
  final String? hostCompetitorId;
  const FinalHostScreen(
      {super.key,
      required this.controller,
      required this.sessionId,
      required this.service,
      required this.store,
      required this.members,
      this.hostCompetitorId});

  @override
  State<FinalHostScreen> createState() => _FinalHostScreenState();
}

class _FinalHostScreenState extends State<FinalHostScreen> {
  FinalsHost? _host;
  Timer? _timer;
  Timer? _refresh;
  late List<FinalsMember> _members = widget.members;
  late final String _me = widget.service.auth.userId;
  bool _saved = false;

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => c.tick());
    _connect();
    // Состав и права обновляем — приглашённые могут присоединиться позже.
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) async {
      final m = await widget.service.members(widget.sessionId);
      if (mounted && m.isNotEmpty) _members = m;
    });
  }

  Timer? _retry;
  int _attempt = 0;
  bool _online = false;

  /// Связь оборвалась: финал идёт дальше на этом телефоне, канал поднимаем заново.
  void _scheduleReconnect() {
    if (!mounted || _retry != null) return;
    setState(() => _online = false);
    final secs = math.min(2 << math.min(_attempt, 3), 15);
    _attempt++;
    _retry = Timer(Duration(seconds: secs), () {
      _retry = null;
      _connect();
    });
    // Таймер уже взведён — повторный onClosed при закрытии канала ничего не удвоит.
    _host?.dispose();
    _host = null;
  }

  Future<void> _connect() async {
    final ch = widget.service.channel(widget.sessionId);
    ch.onClosed = _scheduleReconnect;
    final ok = await ch.join();
    if (!mounted) return;
    if (!ok) {
      if (_attempt == 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
                'Нет связи с участниками — финал идёт только на этом телефоне'))));
      }
      _scheduleReconnect();
      return;
    }
    _attempt = 0;
    setState(() => _online = true);
    _host = FinalsHost(
      controller: c,
      channel: ch,
      allowed: (a) => FinalsSessionService.scopeFor(a, _me, _members),
      canControl: (a) => FinalsSessionService.canControl(a, _me, _members),
    );
    _host!.broadcast();
  }

  final _tracker = AnnounceTracker();
  final _phaseVoice = PhaseAnnouncer();

  void _onChange() {
    if (!mounted) return;
    if (FinalsPrefs.voice(widget.store.db)) {
      final cmd = _phaseVoice.update(c.phase.name,
          secondsLeft: c.secondsLeft, announcing: c.announcing);
      if (cmd != null)
        FinalsAnnouncer.say(widget.store.db, cmd,
            refs: _phaseVoice.lastRef == null ? null : [_phaseVoice.lastRef!]);
      final text = _tracker.update(
        [for (final r in c.live) AnnounceRow(r.c.name, r.total, r.c.active)],
        announcing: c.announcing,
      );
      if (text != null)
        FinalsAnnouncer.say(widget.store.db, text, refs: _tracker.lastRefs);
    }
    if (c.phase == RunPhase.finished && !_saved) {
      _saved = true;
      _timer?.cancel();
      final rec = c.toRecord()
        ..['custom'] = true; // финал тренера в рейтинг не идёт
      FinalsRepository(widget.store.db).save(rec);
      widget.service.end(widget.sessionId);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted)
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => FinalResultScreen(record: rec)));
      });
    }
    setState(() {});
  }

  Future<void> _leave() async {
    c.pause();
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Завершить финал?')),
        content: Text(
            tr('Финал будет прекращён для всех, результаты не сохранятся.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Остаться'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Завершить'))),
        ],
      ),
    );
    if (ok == true) {
      _saved = true;
      widget.service.end(widget.sessionId);
      if (mounted) Navigator.of(context).pop();
    } else {
      c.resume();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refresh?.cancel();
    _retry?.cancel();
    c.removeListener(_onChange);
    _host?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: FinalRoomView(
        snapshot: FinalsSnapshot.of(c),
        role: widget.hostCompetitorId == null
            ? FinalsRole.coach
            : FinalsRole.athlete,
        ownId: widget.hostCompetitorId,
        onShoot: (who, mm) => c.submitShotFor(who, mm.dx, mm.dy),
        onUndo: (who) => c.undoShotFor(who),
        onNext: c.advance,
        onPause: c.paused ? c.resume : c.pause,
        onLeave: _leave,
        offline: !_online,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Гость: спортсмен, помощник или второй тренер на своём телефоне.

class FinalGuestScreen extends StatefulWidget {
  final FinalsMember member;
  final FinalsSessionService service;
  const FinalGuestScreen(
      {super.key, required this.member, required this.service});

  @override
  State<FinalGuestScreen> createState() => _FinalGuestScreenState();
}

class _FinalGuestScreenState extends State<FinalGuestScreen> {
  FinalsGuest? _guest;
  FinalsSnapshot?
      _last; // последнее известное состояние (показываем при обрыве)
  Timer? _hello;
  Timer? _retry;
  int _attempt = 0;
  bool _online = false;

  @override
  void initState() {
    super.initState();
    _join();
  }

  void _scheduleReconnect() {
    if (!mounted || _retry != null) return;
    setState(() => _online = false);
    final secs = math.min(2 << math.min(_attempt, 3), 15);
    _attempt++;
    _retry = Timer(Duration(seconds: secs), () {
      _retry = null;
      _join();
    });
    // Таймер уже взведён — повторный onClosed при закрытии канала ничего не удвоит.
    _guest?.dispose();
    _guest = null;
  }

  Future<void> _join() async {
    final ch = widget.service.channel(widget.member.sessionId);
    ch.onClosed = _scheduleReconnect;
    final ok = await ch.join();
    if (!mounted) return;
    if (!ok) {
      _scheduleReconnect();
      return;
    }
    _attempt = 0;
    final g = FinalsGuest(channel: ch, userId: widget.service.auth.userId)
      ..addListener(() {
        if (!mounted) return;
        final snap = _guest?.snapshot;
        // Озвучка и команды — только у ведущего (одна на всех); у гостя тишина.
        setState(() => _last = snap ?? _last);
      });
    _guest = g;
    g.hello();
    // Пока состояния нет (хозяин ещё не в сети) — повторяем запрос.
    _hello?.cancel();
    _hello = Timer.periodic(const Duration(seconds: 3), (_) {
      if (g.snapshot == null) g.hello();
    });
    setState(() => _online = true);
  }

  @override
  void dispose() {
    _hello?.cancel();
    _retry?.cancel();
    _guest?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = _guest;
    final snap = g?.snapshot ?? _last;
    if (snap == null) {
      return Scaffold(
        appBar: GlassHeader(title: Text(tr('Финал'))),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const AppLoader(),
            const SizedBox(height: 12),
            Text(_attempt > 2
                ? tr('Нет связи, пробуем снова…')
                : tr('Ждём ведущего…')),
          ]),
        ),
      );
    }
    final role = widget.member.role;
    return FinalRoomView(
      snapshot: snap,
      role: role,
      ownId: widget.member.targetId,
      onShoot: (who, mm) => g?.shoot(who, mm.dx, mm.dy),
      onUndo: (who) => g?.undo(who),
      onNext: role == FinalsRole.coach ? () => g?.next() : null,
      offline: !_online,
    );
  }
}

/// Проверяет приглашения в финалы и, если есть ожидающие ответа, предлагает
/// принять — работает из любого места (например, при открытии мессенджера),
/// не зависит от того, включён ли модуль «Финалы».
bool _offeringInvite = false;
final Set<String> _laterInvites = {}; // «Позже» — до перезапуска не напоминаем

Future<void> offerFinalInvites(BuildContext context, AppDataStore store) async {
  if (_offeringInvite) return;
  _offeringInvite = true;
  try {
    await _offerFinalInvites(context, store);
  } finally {
    _offeringInvite = false;
  }
}

Future<void> _offerFinalInvites(
    BuildContext context, AppDataStore store) async {
  final svc = FinalsSessionService(ChatAuthService(store.db));
  final list = [
    for (final m in await svc.myInvitations())
      if (m.status == 'invited' && !_laterInvites.contains(m.sessionId)) m
  ];
  if (list.isEmpty || !context.mounted) return;
  final m = list.first;
  final role = switch (m.role) {
    FinalsRole.athlete => tr('финалистом'),
    FinalsRole.helper => tr('помощником'),
    FinalsRole.coach => tr('тренером'),
  };
  final accept = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Приглашение в финал')),
      content: Text(
          tr('Вас приглашают участвовать {r}. Войти сейчас?', {'r': role})),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Позже'))),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Принять'))),
      ],
    ),
  );
  if (accept != true) {
    if (accept == false) _laterInvites.add(m.sessionId);
    return;
  }
  if (!context.mounted) return;
  if (!await svc.answer(m, accept: true) || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FinalGuestScreen(member: m, service: svc)));
}
