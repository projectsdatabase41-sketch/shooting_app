import 'demo_mode.dart';
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'peer_link.dart';
import 'remote_config.dart';

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

  static List<Map<String, dynamic>>? _iceCache;
  static DateTime _iceAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<List<Map<String, dynamic>>> _ice() async {
    final fallback = [
      {'urls': RemoteConfig.stunServers},
    ];
    final get = iceServers;
    if (get == null) return fallback;
    if (_iceCache != null && DateTime.now().difference(_iceAt) < const Duration(minutes: 10)) return _iceCache!;
    try {
      final r = await get().timeout(const Duration(seconds: 4));
      if (r.isNotEmpty) {
        _iceCache = r;
        _iceAt = DateTime.now();
        return r;
      }
    } catch (_) {}
    return fallback;
  }

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  final List<RTCIceCandidate> _early = [];
  bool _remoteSet = false;
  bool _closed = false;
  void Function()? _onState;
  void Function(Map<String, dynamic> signal)? _onSignal;
  void Function(String data)? _onMessage;
  Timer? _timeout;

  // Диагностика: почему P2P не поднялся (уходит в отзывы, если соединение так и не открылось).
  bool _everOpen = false;
  final List<String> _diag = [];
  final Map<String, int> _cands = {};

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
      final ice = await _ice();
      _diag.add('ice=${ice.map((e) {
        final u = e['urls'];
        return (u is List ? u : [u]).map((x) => '$x'.split(':').first).toSet().join('+');
      }).join(',')} initiator=$initiator');
      final pc = await createPeerConnection({
        'iceServers': ice,
      });
      _pc = pc;
      pc.onIceCandidate = (c) {
        if (c.candidate == null || _closed) return;
        final m = RegExp(r' typ (\w+)').firstMatch(c.candidate!);
        if (m != null) _cands[m.group(1)!] = (_cands[m.group(1)] ?? 0) + 1;
        _onSignal?.call({'kind': 'ice', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      };
      pc.onConnectionState = (s) {
        _diag.add('conn=${s.name}');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          close();
        }
      };
      // Не поднялось за 15 с — сдаёмся, остаёмся на Broadcast.
      _timeout = Timer(const Duration(seconds: 20), () {
        if (!isOpen) close();
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
        case 'answer':
          await pc.setRemoteDescription(RTCSessionDescription(s['sdp'] as String?, 'answer'));
          _remoteSet = true;
          await _flushEarly();
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
