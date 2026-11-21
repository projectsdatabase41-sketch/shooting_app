import 'demo_mode.dart';
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'ice_servers.dart';
import 'peer_link.dart';

/// Реализация на `flutter_webrtc`. Только STUN из удалённого конфига: TURN
/// требует секретных учётных данных, а конфиг публичный — без TURN часть
/// пар (жёсткий мобильный NAT, примерно каждая пятая) не соединится и
/// останется на Broadcast/базе, что нормально.
class WebRtcPeerLink implements PeerLink {
  /// Источник ICE-серверов (STUN+TURN от сервера звонков). Без него или при
  /// сбое — только STUN из конфига. TURN поднимает долю пар, у которых
  /// прямой путь закрыт NAT оператора.
  WebRtcPeerLink({this.iceServers});

  final Future<List<Map<String, dynamic>>> Function()? iceServers;

  /// ICE-серверы: STUN из конфига + TURN от сервера звонков + бесплатный
  /// резерв. Логика и кэш — в `IceServers`, чтобы звонки и P2P брали одно и
  /// то же (без TURN пары за симметричным NAT оставались на Connecting).
  late final IceServers _iceModule = IceServers(fetch: iceServers);

  Future<List<Map<String, dynamic>>> _ice() => _iceModule.get();

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  final List<RTCIceCandidate> _early = [];
  /// Свои кандидаты: если они ушли раньше, чем у собеседника появилось
  /// удалённое описание, он их не применил. После установки offer/answer
  /// отправляем весь список заново — это и лечит «кандидаты: нет» в отчётах
  /// 14.11 с веба.
  final List<RTCIceCandidate> _localCands = [];
  bool _remoteSet = false;
  bool _closed = false;
  bool _initiator = false;

  /// Сигналы, пришедшие раньше, чем появилось соединение. Раньше они
  /// молча выбрасывались: отвечающая сторона зовёт `start(initiator: false)`
  /// без await и сразу отдаёт offer, `_pc` в этот момент ещё null — offer
  /// терялся, ответ не создавался, ICE не запускался вовсе. В отчётах это
  /// выглядело как «кандидаты: нет» у собеседника (20.11).
  final List<Map<String, dynamic>> _queuedSignals = [];
  bool _starting = false;

  /// Одна повторная попытка пересобрать маршрут (restartIce). Отзывы 12–13.11:
  /// «прямое соединение не поднялось», при этом host-кандидатов было 30 — то есть
  /// сеть была, а ICE успевал сдаться раньше, чем приходил рабочий маршрут.
  bool _retried = false;
  Timer? _disconnectTimer;
  void Function()? _onState;
  void Function(Map<String, dynamic> signal)? _onSignal;
  void Function(String data)? _onMessage;
  Timer? _timeout;

  // Диагностика: почему P2P не поднялся (уходит в отзывы, если соединение так и не открылось).
  bool _everOpen = false;
  final List<String> _diag = [];
  final Map<String, int> _cands = {};

  /// Диагностические записи для отладки (используется в тестах и отзывах).
  List<String> get diag => _diag;

  /// Сколько собрано кандидатов по типам (host / srflx / relay).
  Map<String, int> get candidates => Map.unmodifiable(_cands);

  /// Само соединение — нужно диагностике, чтобы прочитать выбранную ICE-пару
  /// и её задержку (`getStats`). В остальном коде используйте методы класса.
  RTCPeerConnection? get pc => _pc;

  @override
  bool get isOpen => !_closed && _dc?.state == RTCDataChannelState.RTCDataChannelOpen;

  @override
  set onMessage(void Function(String data)? cb) => _onMessage = cb;

  @override
  set onState(void Function()? cb) => _onState = cb;

  @override
  set onSignal(void Function(Map<String, dynamic> signal)? cb) => _onSignal = cb;

  @override
  Future<void> start({required bool initiator}) async {
    _starting = true;
    try {
      _initiator = initiator;
      final ice = await _ice();
      _diag.add('warm ice=${ice.map((e) {
        final u = e['urls'];
        return (u is List ? u : [u]).map((x) => '$x'.split(':').first).toSet().join('+');
      }).join(',')} turn=${IceServers.lastTurnProvider ?? 'none'} turnHost=${IceServers.turnHosts(ice)} initiator=$initiator');
      final pc = await createPeerConnection({
        'iceServers': ice,
      });
      _pc = pc;
      pc.onIceCandidate = (c) {
        if (c.candidate == null || _closed) return;
        final m = RegExp(r' typ (\w+)').firstMatch(c.candidate!);
        if (m != null) _cands[m.group(1)!] = (_cands[m.group(1)] ?? 0) + 1;
        // 200, а не 100: на Android собирается 111 кандидатов (host:57
        // srflx:21 relay:33), и хвост relay-кандидатов в повтор не попадал.
        if (_localCands.length < 200) _localCands.add(c);
        _onSignal?.call({'kind': 'ice', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      };
      pc.onConnectionState = (s) {
        _diag.add('conn=${s.name}');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // «Disconnected» часто временный: телефон переключился Wi-Fi → LTE.
          // Раньше мы закрывали канал сразу; теперь даём 8 секунд на восстановление.
          _disconnectTimer?.cancel();
          _disconnectTimer = Timer(const Duration(seconds: 8), () {
            // Не закрываем сразу: разрыв часто временный (переключение сети),
            // поэтому сначала пробуем пересобрать маршрут — раньше здесь было
            // close() без restartIce, и в отчётах 14.11 (Android, host:15
            // srflx:3) не было даже метки о повторе.
            if (!_closed && !isOpen) _retryOrClose();
          });
          return;
        }
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _disconnectTimer?.cancel();
          return;
        }
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _retryOrClose();
          return;
        }
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) close();
      };
      // Не поднялось за 20 с — одна попытка пересобрать маршрут, потом сдаёмся.
      _timeout = Timer(const Duration(seconds: 20), () {
        if (!_closed && !isOpen) _retryOrClose();
      });
      if (initiator) {
        _attach(await pc.createDataChannel('chat', RTCDataChannelInit()..ordered = true));
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        _onSignal?.call({'kind': 'offer', 'sdp': offer.sdp});
      } else {
        pc.onDataChannel = _attach;
      }
    } catch (e) {
      _diag.add('exc=$e');
      _starting = false;
      close();
      return;
    }
    _starting = false;
    await _drainSignals();
  }

  /// Отдать сигналы, накопившиеся до создания соединения, в исходном порядке.
  Future<void> _drainSignals() async {
    if (_closed) {
      _queuedSignals.clear();
      return;
    }
    while (_queuedSignals.isNotEmpty) {
      final s = _queuedSignals.removeAt(0);
      await handleSignal(s);
    }
  }

  /// Один повтор: просим ICE пересобрать кандидатов и, если мы инициатор,  /// отправляем новый offer. Если и это не помогло за 12 с — закрываем канал
  /// (чат продолжит работать через Broadcast/базу).
  Future<void> _retryOrClose() async {
    if (_closed || isOpen) return;
    final pc = _pc;
    if (_retried || pc == null) {
      close();
      return;
    }
    _retried = true;
    _diag.add('retry restartIce');
    try {
      // Если прямые пути не сработали, но ретранслятор (relay) собран —
      // переводим соединение на TURN. Без этого чат оставался без P2P, хотя
      // TURN был доступен (отзывы 19.11: host/srflx/relay собраны, соединения нет).
      if ((_cands['relay'] ?? 0) > 0) {
        try {
          final servers = await _iceModule.get();
          await pc.setConfiguration({
            'iceServers': servers,
            'iceTransportPolicy': 'relay',
          });
          _diag.add('relay=forced');
        } catch (e) {
          _diag.add('relay exc=$e');
        }
      }
      await pc.restartIce();
      if (_initiator) {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        _onSignal?.call({'kind': 'offer', 'sdp': offer.sdp});
      }
    } catch (e) {
      _diag.add('retry exc=$e');
      close();
      return;
    }
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 12), () {
      if (!_closed && !isOpen) close();
    });
  }

  void _attach(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (st) {
      if (st == RTCDataChannelState.RTCDataChannelOpen) _everOpen = true;
      if (st == RTCDataChannelState.RTCDataChannelOpen || st == RTCDataChannelState.RTCDataChannelClosed) {
        _onState?.call();
      }
    };
    dc.onMessage = (m) {
      if (!m.isBinary) _onMessage?.call(m.text);
    };
  }

  @override
  Future<void> handleSignal(Map<String, dynamic> s) async {
    if (_closed) return;
    final pc = _pc;
    if (pc == null) {
      // Соединение ещё создаётся (см. _queuedSignals): не теряем сигнал,
      // а вернёмся к нему после start().
      if (_starting || _queuedSignals.length < 100) _queuedSignals.add(s);
      return;
    }
    try {
      switch (s['kind']) {
        case 'offer':
          await pc.setRemoteDescription(RTCSessionDescription(s['sdp'] as String?, 'offer'));
          _remoteSet = true;
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          _onSignal?.call({'kind': 'answer', 'sdp': answer.sdp});
          await _flushEarly();
          _resendLocal();
        case 'answer':
          await pc.setRemoteDescription(RTCSessionDescription(s['sdp'] as String?, 'answer'));
          _remoteSet = true;
          await _flushEarly();
          _resendLocal();
        case 'ice':
          final c = RTCIceCandidate(s['candidate'] as String?, s['sdpMid'] as String?, s['sdpMLineIndex'] as int?);
          if (_remoteSet) {
            await pc.addCandidate(c);
          } else {
            _early.add(c); // кандидаты могут прийти раньше offer/answer
          }
      }
    } catch (e) {
      // Не рвём соединение из-за одного неудачного сигнала (например,
      // addCandidate в неподходящем состоянии): раньше close() здесь гасил
      // линк, и все следующие сигналы уже не принимались.
      _diag.add('signal exc=$e');
    }
  }

  Future<void> _flushEarly() async {
    for (final c in _early) {
      await _pc?.addCandidate(c);
    }
    _early.clear();
  }

  /// Повторная отправка своих кандидатов после установки удалённого описания.
  void _resendLocal() {
    if (_localCands.isEmpty) return;
    _diag.add('resend-ice:${_localCands.length}');
    for (final c in _localCands) {
      _onSignal?.call({'kind': 'ice', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    }
  }

  @override
  bool send(String data) {
    if (!isOpen) return false;
    try {
      _dc!.send(RTCDataChannelMessage(data));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void close({bool silent = false}) {
    if (_closed) return;
    _closed = true;
    _timeout?.cancel();
    _disconnectTimer?.cancel();
    _queuedSignals.clear();
    // silent — закрытие по инициативе самой диагностики: отчёт «P2P failed»
    // на её прогон не нужен, иначе каждый запуск диагностики присылал
    // ложную ошибку в отзывы (20.11).
    if (!_everOpen && !silent) {
      DemoMode.sendError('P2P failed', 'прямое соединение не поднялось', null,
          '${_diag.join(' ')} '
          'кандидаты: ${_cands.isEmpty ? 'нет' : _cands.entries.map((e) => '${e.key}:${e.value}').join(' ')}');
    }
    try {
      _dc?.close();
      _pc?.close();
    } catch (_) {}
    _onState?.call();
  }
}

