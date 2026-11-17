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
        if (_localCands.length < 100) _localCands.add(c);
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
      close();
    }
  }

  /// Один повтор: просим ICE пересобрать кандидатов и, если мы инициатор,
  /// отправляем новый offer. Если и это не помогло за 12 с — закрываем канал
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
    final pc = _pc;
    if (pc == null || _closed) return;
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
    } catch (_) {
      close();
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
  void close() {
    if (_closed) return;
    _closed = true;
    _timeout?.cancel();
    _disconnectTimer?.cancel();
    if (!_everOpen) {
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
