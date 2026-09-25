import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'call_service.dart';
import 'chat_auth_service.dart';

enum CallState { preparing, calling, ringing, connecting, active, ended }

/// Один звонок один-на-один (аудио или видео). Разговор — напрямую между
/// устройствами (WebRTC); через сервер звонков идёт только «знакомство» в
/// комнате `callId`: offer / answer / ice, а также decline / hangup.
///
/// Исходящий: [start] → комната → push собеседнику → он входит → offer.
/// Входящий: [accept] → комната → ждём offer звонящего → answer.
class CallSession extends ChangeNotifier {
  CallSession._({
    required this.auth,
    required this.callId,
    required this.peerId,
    required this.peerName,
    required this.outgoing,
    required this.video,
  }) : state = outgoing ? CallState.preparing : CallState.ringing;

  factory CallSession.outgoing(ChatAuthService auth, {required String peerId, required String peerName, required bool video}) =>
      CallSession._(auth: auth, callId: const Uuid().v4(), peerId: peerId, peerName: peerName, outgoing: true, video: video);

  factory CallSession.incoming(ChatAuthService auth,
          {required String callId, required String peerId, required String peerName, required bool video}) =>
      CallSession._(auth: auth, callId: callId, peerId: peerId, peerName: peerName, outgoing: false, video: video);

  /// Звонок, который сейчас идёт (второй в то же время не начинаем).
  static CallSession? current;

  final ChatAuthService auth;
  final String callId;
  final String peerId;
  final String peerName;
  final bool outgoing;
  final bool video;

  CallState state;
  String? endReason;
  DateTime? activeSince;
  bool muted = false;
  bool speaker = false;
  bool cameraOff = false;
  bool remoteVideo = false;

  /// Разговор состоялся (дошли до «активен») и его длительность.
  bool get answered => activeSince != null;
  Duration get talked => activeSince == null ? Duration.zero : (_endedAt ?? DateTime.now()).difference(activeSince!);
  DateTime? _endedAt;

  /// Почему закончился (для записи в переписку): answered / declined /
  /// missed / busy / failed / cancelled.
  String outcome = '';

  Timer? _disconnectTimer;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  late final CallService _service = CallService(auth);
  RTCPeerConnection? _pc;
  MediaStream? _local;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _ringTimeout;
  final List<RTCIceCandidate> _pendingIce = [];
  bool _remoteSet = false;
  bool _offerSent = false;

  /// Сколько ждём ответа на исходящий.
  static const Duration ringTimeout = Duration(seconds: 45);

  bool get isEnded => state == CallState.ended;

  void _set(CallState s) {
    if (isEnded) return;
    state = s;
    if (s == CallState.active) activeSince ??= DateTime.now();
    notifyListeners();
  }

  Future<void> _prepareMedia() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video ? {'facingMode': 'user'} : false,
    });
    localRenderer.srcObject = _local;
    final pc = await createPeerConnection({'iceServers': await _service.iceServers()});
    _pc = pc;
    for (final t in _local!.getTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate != null) {
        _send({'type': 'ice', 'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      }
    };
    pc.onTrack = (e) {
      if (e.streams.isEmpty) return;
      remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') remoteVideo = true;
      notifyListeners();
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _disconnectTimer?.cancel();
        _set(CallState.active);
      }
      // Кратковременный обрыв (смена Wi-Fi на мобильный и т.п.) WebRTC часто
      // переживает сам — ждём 10 с, потом сдаёмся.
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _disconnectTimer?.cancel();
        _disconnectTimer = Timer(const Duration(seconds: 10), () => _end('Связь прервалась', outcome: 'failed'));
      }
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) _end('Связь прервалась', outcome: 'failed');
    };
    // Видео — на громкую связь, голос — к уху (как в обычных звонилках).
    await setSpeaker(video);
  }

  Future<void> _openRoom() async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception('Сначала войдите в мессенджер');
    final ws = WebSocketChannel.connect(CallService.roomUri(callId, token));
    await ws.ready;
    _ws = ws;
    _wsSub = ws.stream.listen(
      (raw) => _onSignal(jsonDecode(raw as String) as Map<String, dynamic>),
      onDone: () {
        if (state != CallState.active) _end('Нет связи с сервером звонков');
      },
      onError: (_) => _end('Нет связи с сервером звонков'),
    );
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _ws?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  /// Исходящий звонок.
  Future<void> start() async {
    current = this;
    try {
      await _prepareMedia();
      await _openRoom();
      _set(CallState.calling);
      final delivered = await _service.ring(callId: callId, to: peerId, name: auth.nickname, video: video);
      if (delivered == 0) {
        _end('$peerName сейчас недоступен — нет устройства с приложением', outcome: 'failed');
        return;
      }
      _ringTimeout = Timer(ringTimeout, () {
        if (state == CallState.calling) {
          _service.cancel(callId: callId, to: peerId);
          _end('Не отвечает', outcome: 'missed');
        }
      });
    } catch (e) {
      _end(_humanError(e), outcome: 'failed');
    }
  }

  /// Принять входящий.
  Future<void> accept() async {
    current = this;
    _set(CallState.connecting);
    try {
      await _prepareMedia();
      await _openRoom();
    } catch (e) {
      _end(_humanError(e));
    }
  }

  /// Отклонить входящий: сообщаем звонящему через комнату.
  Future<void> decline() async {
    try {
      await _openRoom();
      _send({'type': 'decline'});
    } catch (_) {}
    _end('Вы отклонили звонок', outcome: 'declined');
  }

  /// Уже идёт другой разговор — сразу отвечаем звонящему «занято».
  Future<void> rejectBusy() async {
    try {
      await _openRoom();
      _send({'type': 'busy'});
    } catch (_) {}
    _end('Линия занята', outcome: 'busy');
  }

  /// Звонящий передумал до ответа (push call_end).
  void cancelledByCaller() {
    if (state == CallState.ringing) _end('Звонок отменён', outcome: 'missed');
  }

  Future<void> hangUp() async {
    final beforeAnswer = !answered;
    if (outgoing && beforeAnswer) _service.cancel(callId: callId, to: peerId);
    _send({'type': 'hangup'});
    _end(answered ? 'Звонок завершён' : 'Звонок отменён', outcome: beforeAnswer ? 'cancelled' : 'answered');
  }

  Future<void> _onSignal(Map<String, dynamic> m) async {
    final pc = _pc;
    switch (m['type']) {
      case 'peers':
        if (state == CallState.ringing) return; // отклоняем — ответ не нужен
        // Входящий: звонящего в комнате уже нет — он передумал.
        if (!outgoing && !(m['peers'] as List).contains(peerId)) _end('Звонок отменён', outcome: 'missed');
        // Исходящий: собеседник уже там (переподключение) — предлагаем соединение.
        if (outgoing && (m['peers'] as List).contains(peerId)) await _makeOffer();
      case 'join':
        if (outgoing && m['from'] == peerId) await _makeOffer();
      case 'offer':
        if (pc == null) return;
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'offer'));
        _remoteSet = true;
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _send({'type': 'answer', 'sdp': answer.sdp});
        await _flushIce();
      case 'answer':
        if (pc == null) return;
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String?, 'answer'));
        _remoteSet = true;
        await _flushIce();
      case 'ice':
        final c = RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, (m['sdpMLineIndex'] as num?)?.toInt());
        if (_remoteSet && pc != null) {
          await pc.addCandidate(c);
        } else {
          _pendingIce.add(c); // кандидаты могут прийти раньше offer/answer
        }
      case 'decline':
        _end('$peerName отклонил звонок', outcome: 'declined');
      case 'busy':
        _end('$peerName сейчас разговаривает — линия занята', outcome: 'busy');
      case 'hangup':
      case 'leave':
        if (m['from'] == peerId) {
          _end(answered ? 'Звонок завершён' : 'Звонок отменён', outcome: answered ? 'answered' : (outgoing ? 'missed' : 'missed'));
        }
    }
  }

  Future<void> _makeOffer() async {
    final pc = _pc;
    if (pc == null || _offerSent) return;
    _offerSent = true;
    _ringTimeout?.cancel();
    _set(CallState.connecting);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _send({'type': 'offer', 'sdp': offer.sdp});
  }

  Future<void> _flushIce() async {
    for (final c in _pendingIce) {
      await _pc?.addCandidate(c);
    }
    _pendingIce.clear();
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> setSpeaker(bool on) async {
    speaker = on;
    try {
      if (!kIsWeb) await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
    notifyListeners();
  }

  void _end(String reason, {String? outcome}) {
    if (isEnded) return;
    endReason = reason;
    this.outcome = outcome ?? (answered ? 'answered' : 'failed');
    _endedAt = DateTime.now();
    state = CallState.ended;
    _ringTimeout?.cancel();
    _disconnectTimer?.cancel();
    _wsSub?.cancel();
    try {
      _ws?.sink.close();
    } catch (_) {}
    for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      t.stop();
    }
    _local?.dispose();
    _pc?.close();
    if (current == this) current = null;
    notifyListeners();
  }

  static String _humanError(Object e) {
    final s = '$e';
    if (s.contains('Permission') || s.contains('NotAllowed')) return 'Нет доступа к микрофону или камере';
    return 'Не удалось начать звонок: $s';
  }

  @override
  void dispose() {
    if (!isEnded) hangUp();
    localRenderer.dispose();
    remoteRenderer.dispose();
    super.dispose();
  }
}
