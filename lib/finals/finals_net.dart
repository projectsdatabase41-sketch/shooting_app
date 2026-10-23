import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/demo_mode.dart';
import '../services/realtime_client.dart';
import 'final_run.dart';

/// Канал совместного финала: «хозяин» шлёт состояние, участники — выстрелы.
abstract class FinalsChannel {
  void Function(String event, Map<String, dynamic> payload)? onMessage;
  void Function()? onClosed;
  Future<bool> join();
  bool send(String event, Map<String, dynamic> payload);
  void close();
}

/// Канал поверх Supabase Realtime (приватный Broadcast `final:<session>`),
/// тот же клиент, что у живого чата.
class RealtimeFinalsChannel implements FinalsChannel {
  RealtimeFinalsChannel({
    required String baseUrl,
    required String anonKey,
    required String sessionId,
    required String userId,
    required this.token,
    bool isPrivate = true,
  }) : _client = RealtimeChannelClient(
          baseUrl: baseUrl,
          anonKey: anonKey,
          topic: 'final:$sessionId',
          presenceKey: userId,
          private: isPrivate,
        );

  final RealtimeChannelClient _client;
  final Future<String?> Function() token;

  @override
  void Function(String event, Map<String, dynamic> payload)? onMessage;
  @override
  void Function()? onClosed;

  @override
  Future<bool> join() async {
    final t = await token();
    if (t == null) {
      DemoMode.sendError('Finals realtime join', 'нет токена мессенджера');
      return false;
    }
    _client.onBroadcast = (e, p) => onMessage?.call(e, p);
    _client.onClosed = () => onClosed?.call();
    final ok = await _client.join(t);
    // Тихо сообщаем разработчику, если подключиться к каналу не удалось (причина «ждём ведущего»).
    if (!ok) DemoMode.sendError('Finals realtime join', 'канал не открылся ');
    return ok;
  }

  @override
  bool send(String event, Map<String, dynamic> payload) => _client.sendBroadcast(event, payload);

  @override
  void close() => _client.close();
}

/// Пара каналов в памяти (тесты и локальная отладка).
class MemoryFinalsChannel implements FinalsChannel {
  MemoryFinalsChannel._();
  MemoryFinalsChannel? _peer;
  bool closed = false;

  static (MemoryFinalsChannel, MemoryFinalsChannel) pair() {
    final a = MemoryFinalsChannel._(), b = MemoryFinalsChannel._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  void Function(String event, Map<String, dynamic> payload)? onMessage;
  @override
  void Function()? onClosed;

  @override
  Future<bool> join() async => true;

  @override
  bool send(String event, Map<String, dynamic> payload) {
    if (closed) return false;
    final peer = _peer;
    // Доставка асинхронна, как по сети; копия, чтобы не делить объекты.
    scheduleMicrotask(() => peer?.onMessage?.call(event, Map<String, dynamic>.from(payload)));
    return true;
  }

  @override
  void close() {
    closed = true;
    onClosed?.call();
  }
}

/// Снимок состояния финала для участников.
class FinalsSnapshot {
  final Map<String, dynamic> data;
  FinalsSnapshot(this.data);

  String get phase => data['phase'] as String;
  int get secondsLeft => data['left'] as int;
  String get round => data['round'] as String;
  int get roundSeconds => data['rs'] as int;
  int get roundLimit => data['rl'] as int;
  bool get paused => data['paused'] == true;
  int get shotsPerShooter => data['spp'] as int;
  String get face => data['face'] as String;
  String get format => data['fmt'] as String;
  List<Map<String, dynamic>> get rows => (data['rows'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic>? row(String id) {
    for (final r in rows) {
      if (r['id'] == id) return r;
    }
    return null;
  }

  static FinalsSnapshot of(FinalRunController c) {
    final live = c.live;
    final lastShot = <String, RunShot>{};
    for (final s in c.shots) {
      if (!s.shootOff) lastShot[s.who] = s;
    }
    return FinalsSnapshot({
      'phase': c.phase.name,
      'left': c.secondsLeft,
      'round': c.roundLabel,
      'rs': c.roundSeconds,
      'rl': c.roundLimit,
      'paused': c.paused,
      'spp': c.shotsPerShooter,
      'face': c.face.code,
      'fmt': c.format.id,
      'vm': c.voiceAll ? 'all' : 'chief',
      'hs': c.hostSilent,
      'ch': c.chiefHint,
      'rows': [
        for (final r in live)
          {
            'id': r.c.id,
            'name': r.c.name,
            'human': c.humans.contains(r.c.id),
            'active': r.c.active,
            'place': r.c.place,
            'total': r.total,
            'avg': r.avg,
            'shots': r.shots,
            if (lastShot[r.c.id] != null) 'last': [lastShot[r.c.id]!.x, lastShot[r.c.id]!.y],
            if (c.humans.contains(r.c.id))
              'staged': [for (final st in c.stagedOf(r.c.id)) [st.x, st.y]],
            if (c.humans.contains(r.c.id)) 'can': c.canShootFor(r.c.id),
          }
      ],
    });
  }
}

/// «Хозяин» финала: считает его у себя и раздаёт состояние; выстрелы
/// участников применяет, проверив права (роль автора → за кого можно).
class FinalsHost {
  FinalsHost({
    required this.controller,
    required this.channel,
    required this.allowed,
    this.canControl,
    this.onHello,
  }) {
    channel.onMessage = _onMessage;
    controller.addListener(_scheduleBroadcast);
  }

  final FinalRunController controller;
  final FinalsChannel channel;

  /// Права: для автора ([author], id пользователя) — за кого он может стрелять;
  /// `null` — за любого (тренер, хозяин).
  final Set<String>? Function(String author) allowed;

  /// Кто может подавать команды («Далее»). По умолчанию никто, кроме хозяина
  /// на его же телефоне (он жмёт кнопку напрямую).
  final bool Function(String author)? canControl;

  bool _pending = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Не чаще раза в 150 мс; последнее состояние всегда уходит.
  void _scheduleBroadcast() {
    if (_pending) return;
    _pending = true;
    final wait = const Duration(milliseconds: 150) - DateTime.now().difference(_last);
    Timer(wait.isNegative ? Duration.zero : wait, () {
      _pending = false;
      broadcast();
    });
  }

  void broadcast() {
    _last = DateTime.now();
    channel.send('state', FinalsSnapshot.of(controller).data);
  }

  /// Проверка приглашения при подключении гостя ([author] — его токен); `false` — отказ.
  final bool Function(String author, String name)? onHello;

  /// Финал завершён: гости узнают об этом, их приглашения перестают работать.
  void end() => channel.send('ended', const {});

  void _onMessage(String event, Map<String, dynamic> p) {
    final author = '${p['author']}';
    if (event == 'hello') {
      if (onHello?.call(author, '${p['name'] ?? ''}') == false) {
        channel.send('denied', {'to': author});
        return;
      }
      broadcast(); // подключившийся сразу получает состояние
      return;
    }
    if (event == 'next') {
      if (canControl?.call(author) == true) controller.advance();
      return;
    }
    final who = '${p['who']}';
    final scope = allowed(author);
    if (scope != null && !scope.contains(who)) return; // чужой выстрел — игнор
    switch (event) {
      case 'shot':
        controller.submitShotFor(who, (p['x'] as num).toDouble(), (p['y'] as num).toDouble());
      case 'undo':
        controller.undoShotFor(who);
    }
  }

  void dispose() {
    controller.removeListener(_scheduleBroadcast);
    channel.close();
  }
}

/// Участник финала (спортсмен, тренер, помощник): получает состояние и шлёт
/// выстрелы хозяину.
class FinalsGuest extends ChangeNotifier {
  FinalsGuest({required this.channel, required this.userId, this.name = ''}) {
    channel.onMessage = (e, p) {
      if (e == 'state') {
        snapshot = FinalsSnapshot(p);
        notifyListeners();
      } else if (e == 'ended') {
        ended = true;
        notifyListeners();
      } else if (e == 'denied' && p['to'] == userId) {
        denied = true;
        notifyListeners();
      }
    };
  }

  final FinalsChannel channel;
  final String userId;
  final String name;
  FinalsSnapshot? snapshot;

  /// Ведущий завершил финал / не признал приглашение.
  bool ended = false;
  bool denied = false;

  /// Запросить текущее состояние (после входа в канал).
  void hello() => channel.send('hello', {'author': userId, 'who': '', 'name': name});

  bool shoot(String who, double x, double y) => channel.send('shot', {'author': userId, 'who': who, 'x': x, 'y': y});
  /// Команда тренера «Далее» (заряжай / старт / стоп).
  bool next() => channel.send('next', {'author': userId, 'who': ''});
  bool undo(String who) => channel.send('undo', {'author': userId, 'who': who});

  @override
  void dispose() {
    channel.close();
    super.dispose();
  }
}
