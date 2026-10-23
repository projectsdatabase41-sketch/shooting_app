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
import '../finals/cheers.dart';
import '../services/user_profile.dart';
import '../finals/final_publish.dart';
import '../finals/finals_board.dart';
import '../finals/finals_invite.dart';
import '../services/supabase_auth_service.dart';
import '../finals/round_label.dart';
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
      return finalRoundLabel(s.format, s.round);
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

  /// Кричалки: лента реакций у всех, кнопки — у зрителя.
  final CheerFeed? cheers;
  final void Function(String kind)? onCheer;

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
    this.cheers,
    this.onCheer,
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
          if (cheers != null)
            ListenableBuilder(
              listenable: cheers!,
              builder: (_, __) => cheers!.items.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(spacing: 6, runSpacing: 4, children: [
                        for (final i in cheers!.items)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('${CheerFeed.kinds[i.kind]!.$1} ${i.name}'),
                          ),
                      ]),
                    ),
            ),
          if (onCheer != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final e in CheerFeed.kinds.entries)
                  IconButton.filledTonal(
                    onPressed: () => onCheer!(e.key),
                    icon: Text(e.value.$1, style: const TextStyle(fontSize: 24)),
                  ),
              ]),
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
  FinalsInvite? invite;
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
  final _book = FinalsInviteBook(); // временные приглашения: хранятся только здесь
  FinalsChannel? _lobbyCh;
  bool _public = false;
  int _maxSpec = 50;
  String? _boardId;
  bool _handedOff = false; // дальше табло ведёт экран ведущего
  bool _busy = false;
  bool _hostShoots =
      false; // ведущий сам стреляет (финал спортсменов без тренера)

  @override
  void dispose() {
    _lobbyCh?.close();
    // Передумали до начала — публичный финал с табло снимаем.
    if (_boardId != null && !_handedOff) FinalsBoardService(_auth).remove(_boardId!);
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
        SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, FinalsRole.spectator),
            child: Text(tr('Зритель (болеет, кричалки)'))),
      ]),
    );
    if (role != null) setState(() => _picks.add(_Pick(c, role)));
  }

  Future<void> _createAndInvite() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Канал по секретному имени: приглашённые подключаются с личным токеном, в базу ничего не пишется.
    final personal = SupabaseAuthService(_store.db);
    if (personal.hasBase) {
      _book.url = personal.url;
      _book.anonKey = personal.anonKey;
    }
    final ch = FinalsSessionService.publicChannel(_book.key, url: _book.url, anonKey: _book.anonKey);
    ch.onMessage = (e, p) {
      if (e != 'hello') return;
      final who = '${p['author']}';
      if (_book.accept(who, '${p['name'] ?? ''}')) {
        if (mounted) setState(() => _members = _book.members);
      } else {
        ch.send('denied', {'to': who});
      }
    };
    if (!await ch.join()) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Не удалось создать финал. Мы уже получили отчёт — попробуйте позже'))));
      }
      return;
    }
    _lobbyCh = ch;
    if (_public) {
      _book.isPublic = true;
      _book.maxSpectators = _maxSpec;
      final profile = '${UserProfile.firstNameOf(_store.db)} ${UserProfile.lastNameOf(_store.db)}'.trim();
      _boardId = await FinalsBoardService(_auth).create(
          hostName: profile.isNotEmpty ? profile : _auth.nickname,
          formatId: widget.format.id,
          key: _book.key,
          url: _book.url,
          anonKey: _book.anonKey,
          maxSpectators: _maxSpec);
    }
    for (final p in _picks) {
      final inv = _book.create(
          role: p.role,
          name: p.contact.nickname,
          targetId: p.role == FinalsRole.athlete ? p.targetId : null);
      p.invite = inv;
      // Приглашение уходит сообщением мессенджера (push) вместе с кодом; в базу финала оно не пишется.
      try {
        await ChatSyncService(_auth, ChatMessagesRepository(_store.db)).send(
            p.contact.id,
            '${tr('Приглашаю в финал! Приложение предложит принять приглашение; если нет — вставьте код во вкладке «Финалы».')}\n${inv.encode()}');
      } catch (_) {}
    }
    _sessionId = _book.key;
    _members = _book.members;
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
    controller.isPublic = _public;
    _handedOff = true;
    _lobbyCh?.close();
    _lobbyCh = null;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FinalHostScreen(
          book: _book,
          boardId: _boardId,
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Публичный финал')),
                subtitle: Text(_auth.isSignedIn
                    ? tr('Появится на табло: любой может смотреть и болеть, результаты участников попадут в таблицу чемпионов')
                    : tr('Нужен вход в мессенджер')),
                value: _public,
                onChanged: started || !_auth.isSignedIn ? null : (v) => setState(() => _public = v),
              ),
              if (_public)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Зрителей до {n}', {'n': _maxSpec})),
                  subtitle: Slider(
                    min: 10,
                    max: 150,
                    divisions: 14,
                    value: _maxSpec.toDouble(),
                    label: '$_maxSpec',
                    onChanged: started ? null : (v) => setState(() => _maxSpec = v.round()),
                  ),
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
                    FinalsRole.spectator => tr('Зритель'),
                  }),
                  trailing: started
                      ? Text(_members
                          .where((m) => m.userId == p.invite?.token)
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

  /// Временные приглашения этого финала; после финала стираются.
  final FinalsInviteBook book;

  /// Строка на табло публичных финалов (если финал публичный).
  final String? boardId;

  /// Если ведущий сам стреляет — его id участника; иначе `null` (он только ведёт).
  final String? hostCompetitorId;
  const FinalHostScreen(
      {super.key,
      required this.controller,
      required this.sessionId,
      required this.service,
      required this.store,
      required this.members,
      required this.book,
      this.boardId,
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
  final _cheers = CheerFeed();
  late final _board = FinalsBoardService(widget.service.auth);
  bool _boardLive = false;
  int _tick = 0;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0); // диктор говорит — кричалки без звука

  FinalRunController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.voiceAll = FinalsPrefs.voiceAll(widget.store.db);
    // Ведущий стреляет сам и есть жюри — говорит главный из жюри, у ведущего тишина.
    c.hostSilent = widget.hostCompetitorId != null && widget.members.any((m) => m.role == FinalsRole.coach && m.status == 'accepted');
    c.addListener(_onChange);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => c.tick());
    _connect();
    // Состав и главный из жюри обновляются — приглашённые подключаются по ходу.
    c.chiefHint = widget.book.chiefHint;
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _members = widget.book.members;
      c.chiefHint = widget.book.chiefHint;
      c.hostSilent = widget.hostCompetitorId != null && _members.any((m) => m.role == FinalsRole.coach && m.status == 'accepted');
      // Зрителей много — состояние реже, чтобы не упереться в лимит сообщений.
      _host?.minInterval = _members.length > 14 ? const Duration(seconds: 1) : const Duration(milliseconds: 150);
      // Раз в минуту «жив» на табло.
      if (++_tick % 20 == 0 && widget.boardId != null && c.phase != RunPhase.finished) {
        _board.update(widget.boardId!, status: _boardLive ? 'live' : 'preparing');
      }
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
    final ch = FinalsSessionService.publicChannel(widget.sessionId, url: widget.book.url, anonKey: widget.book.anonKey);
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
      cheerName: (a) {
        for (final m in _members) {
          if (m.userId == a && m.status == 'accepted') return m.name;
        }
        return null;
      },
      isFull: () => widget.book.full,
      onCheer: (name, kind) {
        _cheers.add(name, kind);
        // Смайлики идут всегда, а голосом реакцию озвучиваем только вне объявлений судьи — чтобы не перебивать.
        if (FinalsPrefs.voice(widget.store.db) && !c.announcing && DateTime.now().isAfter(_quietUntil)) {
          FinalsAnnouncer.speak(CheerFeed.kinds[kind]!.$2, queue: true);
        }
      },
      // Токен проверяется по списку приглашений: стёртый или чужой — отказ.
      onHello: (a, name) {
        final ok = widget.book.accept(a, name);
        if (ok) {
          _members = widget.book.members;
          c.chiefHint = widget.book.chiefHint;
        }
        return ok;
      },
    );
    _host!.broadcast();
  }

  final _tracker = AnnounceTracker();
  final _phaseVoice = PhaseAnnouncer();

  void _onChange() {
    if (!mounted) return;
    if (FinalsPrefs.voice(widget.store.db) && (!c.hostSilent || c.voiceAll)) {
      final cmd = _phaseVoice.update(c.phase.name,
          secondsLeft: c.secondsLeft, announcing: c.announcing);
      if (cmd != null) _quietUntil = DateTime.now().add(const Duration(seconds: 4));
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
    if (c.phase == RunPhase.shooting && !_boardLive) {
      _boardLive = true;
      if (widget.boardId != null) _board.update(widget.boardId!, status: 'live');
    }
    if (c.phase == RunPhase.finished && !_saved) {
      _saved = true;
      _timer?.cancel();
      final isPublic = widget.book.isPublic;
      final rec = c.toRecord()
        ..['custom'] = !isPublic // непубличный финал тренера в рейтинг не идёт
        ..['public'] = isPublic;
      FinalsRepository(widget.store.db).save(rec);
      if (isPublic) {
        if (widget.boardId != null) {
          _board.update(widget.boardId!, status: 'finished', top: [
            for (final st in (rec['standings'] as List).cast<Map<String, dynamic>>().take(8))
              {'name': st['name'], 'place': st['place'], 'total': st['total']}
          ]);
        }
        // Ведущий, если сам стрелял, публикует свой результат так же, как остальные участники.
        if (widget.hostCompetitorId != null) autoPublishFinal(widget.store, rec).then((_) {}, onError: (_) {});
      }
      Future.delayed(const Duration(seconds: 2), () {
        _endSession();
        if (mounted)
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => FinalResultScreen(record: rec)));
      });
    }
    setState(() {});
  }

  /// Финал окончен: гости получают «ended», токены приглашений стираются — старые приглашения не откроют ничего.
  void _endSession() {
    // Досрочно закончили — публичный финал снимаем с табло (оконченный остаётся с итогом).
    if (widget.boardId != null && c.phase != RunPhase.finished) _board.remove(widget.boardId!);
    _host?.end();
    widget.book.erase();
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
      _endSession();
      await Future.delayed(const Duration(milliseconds: 400)); // 'ended' успеет уйти гостям
      if (mounted) Navigator.of(context).pop();
    } else {
      c.resume();
    }
  }

  @override
  void dispose() {
    _cheers.dispose();
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
        cheers: _cheers,
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
  /// База, на которой ведущий открыл канал (из приглашения); `null` — база мессенджера.
  final String? url;
  final String? anonKey;
  const FinalGuestScreen(
      {super.key, required this.member, required this.service, this.url, this.anonKey});

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
  final _tracker = AnnounceTracker();
  final _phaseVoice = PhaseAnnouncer();
  int _helloTicks = 0;
  bool _closing = false;
  final _cheers = CheerFeed();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _join();
  }

  /// Итог у участника: сохраняется в «Финалы» (по очкам из таблицы; координат выстрелов у гостя нет).
  void _saveResult(FinalsSnapshot snap) {
    if (_saved) return;
    _saved = true;
    final rows = [...snap.rows]..sort((a, b) => ((a['place'] ?? 99) as num).compareTo((b['place'] ?? 99) as num));
    final full = snap.data['shots'] as List?; // с координатами — в конце финала присылает ведущий
    final isPublic = snap.data['pub'] == true;
    final rec = <String, dynamic>{
      'format': snap.format,
      'face': snap.face,
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
      'custom': !isPublic,
      'public': isPublic,
      'partial': full == null,
      'standings': [
        for (final r in rows)
          {'id': r['id'], 'name': r['name'], 'place': r['place'], 'total': r['total'], 'user': r['id'] == widget.member.targetId}
      ],
      'shots': full != null
          ? [for (final x in full) (x as Map).cast<String, dynamic>()]
          : [
        for (final r in rows)
          for (var i = 0; i < (r['shots'] as List).length; i++)
            {'who': r['id'], 'i': i, 'x': 0.0, 'y': 0.0, 's': (r['shots'] as List)[i], 't': 0}
      ],
      'log': const [],
    };
    final db = context.read<AppDataStore>().db;
    FinalsRepository(db).save(rec);
    // Публичный финал: результат участника сам уходит в таблицу чемпионов.
    if (isPublic && widget.member.role == FinalsRole.athlete) {
      autoPublishFinal(context.read<AppDataStore>(), rec).then((_) {}, onError: (_) {});
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => FinalResultScreen(record: rec, readOnly: true)));
    });
  }

  void _closeWith(String msg) {
    if (_closing) return;
    _closing = true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    Navigator.of(context).maybePop();
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
    final ch = FinalsSessionService.publicChannel(widget.member.sessionId, url: widget.url, anonKey: widget.anonKey);
    ch.onClosed = _scheduleReconnect;
    final ok = await ch.join();
    if (!mounted) return;
    if (!ok) {
      _scheduleReconnect();
      return;
    }
    _attempt = 0;
    final g = FinalsGuest(channel: ch, userId: widget.member.userId, name: widget.member.name)
      ..addListener(() {
        if (!mounted) return;
        final g = _guest;
        if (g != null && (g.ended || g.denied)) {
          if (!_saved) _closeWith(g.denied ? (g.deniedFull ? tr('Мест для зрителей нет') : tr('Приглашение недействительно: финал уже окончен')) : tr('Финал окончен'));
          return;
        }
        final snap = _guest?.snapshot;
        if (snap != null) {
          final db = context.read<AppDataStore>().db;
          // Говорит ведущий; у гостя — только если включено «у всех» или он главный из жюри, а ведущий молчит.
          final speak = FinalsPrefs.voice(db) && (snap.data['vm'] == 'all' || (snap.data['hs'] == true && widget.member.role == FinalsRole.coach && snap.data['ch'] == FinalsInviteBook.hint(widget.member.userId)));
          final announcing = snap.phase == 'loading' && snap.secondsLeft > 5;
          final cmd = _phaseVoice.update(snap.phase, secondsLeft: snap.secondsLeft, announcing: announcing);
          final text = _tracker.update(
            [for (final r in snap.rows) AnnounceRow('${r['name']}', (r['total'] as num).toDouble(), r['active'] == true, isMe: r['id'] == widget.member.targetId)],
            announcing: announcing,
          );
          if (speak) {
            if (cmd != null) FinalsAnnouncer.say(db, cmd, refs: _phaseVoice.lastRef == null ? null : [_phaseVoice.lastRef!]);
            if (text != null) FinalsAnnouncer.say(db, text, refs: _tracker.lastRefs);
          }
          if (snap.phase == 'finished') _saveResult(snap);
        }
        setState(() => _last = snap ?? _last);
      });
    g.onCheer = _cheers.add;
    _guest = g;
    g.hello();
    // Пока состояния нет (хозяин ещё не в сети) — повторяем запрос.
    _hello?.cancel();
    _hello = Timer.periodic(const Duration(seconds: 3), (_) {
      if (g.snapshot == null) {
        g.hello();
        if (++_helloTicks == 6 && mounted) setState(() {});
      }
    });
    setState(() => _online = true);
  }

  @override
  void dispose() {
    _cheers.dispose();
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
            Text(_helloTicks >= 6
                ? tr('Ведущего нет в сети. Возможно, финал уже окончен.')
                : _attempt > 2
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
      cheers: _cheers,
      onCheer: role == FinalsRole.spectator
          ? (kind) {
              if (g?.cheer(kind) == true) _cheers.add(widget.member.name.isEmpty ? '' : widget.member.name, kind);
            }
          : null,
      offline: !_online,
    );
  }
}

/// Проверяет приглашения в финалы и, если есть ожидающие ответа, предлагает
/// принять — работает из любого места (например, при открытии мессенджера),
/// не зависит от того, включён ли модуль «Финалы».
bool _offeringInvite = false;
final Set<String> _laterInvites = {}; // «Позже» — до перезапуска не напоминаем

/// Приглашения в финал из входящих сообщений (действующие, неиспользованные) — предлагаем принять.
Future<void> offerFinalInvites(BuildContext context, AppDataStore store) async {
  if (_offeringInvite) return;
  _offeringInvite = true;
  try {
    final list = [for (final i in FinalsInviteStore.pending(store.db)) if (!_laterInvites.contains(i.token)) i];
    if (list.isEmpty || !context.mounted) return;
    final inv = list.first;
    final accept = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Приглашение в финал')),
        content: Text(tr('Вас приглашают участвовать {r}. Войти сейчас?', {'r': _roleWord(inv.role)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Позже'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Принять'))),
        ],
      ),
    );
    if (accept != true) {
      if (accept == false) _laterInvites.add(inv.token);
      return;
    }
    if (!context.mounted) return;
    await joinFinal(context, store, inv);
  } finally {
    _offeringInvite = false;
  }
}

String _roleWord(FinalsRole r) => switch (r) {
      FinalsRole.athlete => tr('финалистом'),
      FinalsRole.helper => tr('помощником'),
      FinalsRole.coach => tr('жюри'),
      FinalsRole.spectator => tr('зрителем'),
    };

/// Войти в финал по приглашению. Просроченное — сразу «финал окончен».
Future<void> joinFinal(BuildContext context, AppDataStore store, FinalsInvite inv) async {
  if (inv.expired) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Приглашение недействительно: финал уже окончен'))));
    return;
  }
  FinalsInviteStore.markSeen(store.db, inv.token);
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FinalGuestScreen(
          member: inv.member, service: FinalsSessionService(ChatAuthService(store.db)), url: inv.url, anonKey: inv.anonKey)));
}

/// Вставить код приглашения вручную (если пришёл не через мессенджер).
Future<void> enterFinalByCode(BuildContext context, AppDataStore store) async {
  final ctl = TextEditingController();
  final text = await showGlassDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Код приглашения')),
      content: TextField(controller: ctl, autofocus: true, minLines: 1, maxLines: 4, decoration: InputDecoration(hintText: FinalsInvite.prefix)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Закрыть'))),
        TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(tr('Войти'))),
      ],
    ),
  );
  ctl.dispose();
  if (text == null || !context.mounted) return;
  final inv = FinalsInvite.parse(text);
  if (inv == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Код не распознан'))));
    return;
  }
  await joinFinal(context, store, inv);
}

/// Войти зрителем в публичный финал с табло (приглашение не нужно: токен зритель создаёт сам).
Future<void> joinPublicFinal(BuildContext context, AppDataStore store, FinalsBoardRow row) async {
  final nick = ChatAuthService(store.db).nickname;
  final member = FinalsMember(row.key, newFinalsToken(), FinalsRole.spectator, null, nick.isNotEmpty ? nick : tr('Зритель'), 'accepted');
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FinalGuestScreen(
          member: member, service: FinalsSessionService(ChatAuthService(store.db)), url: row.url, anonKey: row.anonKey)));
}
