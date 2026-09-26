import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/call_session.dart';
import '../services/chat_messages_repository.dart';
import '../services/push_service.dart';
import '../widgets/chat_avatar.dart';
import '../i18n/i18n.dart';

/// Экран звонка: входящий (принять/отклонить), исходящий, разговор и итог.
///
/// Дизайн: фон — градиент в цвет собеседника (тот же, что у его аватара без
/// фото), вокруг аватара пульсируют кольца, пока идёт вызов; кнопки —
/// круглые, на полупрозрачной панели снизу; при видео — видео собеседника
/// на весь экран, своё — окошком в углу.
class CallScreen extends StatefulWidget {
  final CallSession session;
  final String? avatarBase64;

  /// Входящий, уже принятый (кнопкой в уведомлении) — сразу соединяем.
  final bool autoAccept;

  /// Куда записать итог звонка в переписке («Исходящий · 03:12»).
  final ChatMessagesRepository? repo;

  const CallScreen({super.key, required this.session, this.avatarBase64, this.autoAccept = false, this.repo});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  late CallSession s = widget.session;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();
  Timer? _tick;
  Timer? _autoClose;

  @override
  void initState() {
    super.initState();
    _attach(s);
    if (s.outgoing) {
      s.start();
    } else if (widget.autoAccept) {
      _accept();
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (s.state == CallState.active && mounted) setState(() {});
    });
  }

  void _attach(CallSession session) {
    CallSession.current = session;
    session.addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (s.state != CallState.ringing) cancelIncomingCallNotification();
    if (s.isEnded) {
      _log(s);
      // Итог — 3 секунды (или пока не нажмут «Перезвонить»), потом закрыть.
      _autoClose?.cancel();
      _autoClose = Timer(const Duration(seconds: 3), () {
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
    }
  }

  void _accept() {
    cancelIncomingCallNotification();
    s.accept();
  }

  /// Запись о звонке в переписке — только у себя на устройстве.
  void _log(CallSession c) {
    final repo = widget.repo;
    if (repo == null || repo.contactById(c.peerId) == null || c.outcome == 'busy' && !c.outgoing) return;
    final d = c.talked;
    final dur = '${d.inMinutes.toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
    final kind = c.video ? tr('Видеозвонок') : tr('Звонок');
    final text = switch (c.outcome) {
      'answered' => '${c.video ? '🎥' : '📞'} ${c.outgoing ? 'Исходящий' : 'Входящий'} ${kind.toLowerCase()} · $dur',
      'missed' => c.outgoing ? tr('📞 {kind} — нет ответа', {'kind': kind}) : tr('📵 Пропущенный {p}', {'p': kind.toLowerCase()}),
      'declined' => c.outgoing ? tr('📞 {kind} отклонён', {'kind': kind}) : tr('📵 Вы отклонили {p}', {'p': kind.toLowerCase()}),
      'busy' => tr('📞 {kind} — линия занята', {'kind': kind}),
      'cancelled' => tr('📞 {kind} отменён', {'kind': kind}),
      _ => tr('📞 {kind} не состоялся', {'kind': kind}),
    };
    repo.addMessage(ChatMessage(
      id: const Uuid().v4(),
      clientMessageId: 'call-${c.callId}',
      contactId: c.peerId,
      direction: c.outgoing ? ChatMessageDirection.outgoing : ChatMessageDirection.incoming,
      text: text,
      status: ChatMessageStatus.delivered,
      seen: true,
      createdAt: DateTime.now(),
    ));
  }

  void _redial() {
    _autoClose?.cancel();
    final old = s;
    old.removeListener(_onChange);
    final next = CallSession.outgoing(old.auth, peerId: old.peerId, peerName: old.peerName, video: old.video);
    old.dispose();
    setState(() => s = next);
    _attach(next);
    next.start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _autoClose?.cancel();
    _pulse.dispose();
    s.removeListener(_onChange);
    if (CallSession.current == s && s.isEnded) CallSession.current = null;
    s.dispose();
    cancelIncomingCallNotification();
    super.dispose();
  }

  String get _status => switch (s.state) {
        CallState.preparing => tr('Подготовка…'),
        CallState.calling => s.video ? tr('Видеовызов…') : tr('Вызов…'),
        CallState.ringing => s.video ? tr('Входящий видеозвонок') : tr('Входящий звонок'),
        CallState.connecting => tr('Соединение…'),
        CallState.active => _fmt(s.talked),
        CallState.ended => s.answered ? '${s.endReason ?? 'Звонок завершён'} · ${_fmt(s.talked)}' : (s.endReason ?? tr('Звонок завершён')),
      };

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$sec' : '$m:$sec';
  }

  Color get _tint => HSLColor.fromAHSL(
        1,
        (s.peerName.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xFFFF) % 360).toDouble(),
        0.45,
        0.28,
      ).toColor();

  Widget _button(IconData icon, String label, VoidCallback? onTap, {Color? color, bool on = false, double size = 64}) {
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color ?? (on ? Colors.white : Colors.white.withValues(alpha: 0.16)),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, size: size * 0.42, color: color != null ? Colors.white : (on ? _tint : Colors.white)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _avatar() {
    final ringing = s.state == CallState.calling || s.state == CallState.ringing || s.state == CallState.connecting;
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (ringing)
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Stack(
                alignment: Alignment.center,
                children: [
                  for (final phase in [0.0, 0.5])
                    () {
                      final t = (_pulse.value + phase) % 1;
                      return Container(
                        width: 120 + 100 * t,
                        height: 120 + 100 * t,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.35 * (1 - t)), width: 2),
                        ),
                      );
                    }(),
                ],
              ),
            ),
          ChatAvatar(base64: widget.avatarBase64, nickname: s.peerName, radius: 60),
        ],
      ),
    );
  }

  Widget _controls() {
    if (s.state == CallState.ringing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _button(Icons.call_end, tr('Отклонить'), s.decline, color: const Color(0xFFE53935), size: 72),
          _button(s.video ? Icons.videocam : Icons.call, tr('Принять'), _accept, color: const Color(0xFF43A047), size: 72),
        ],
      );
    }
    if (s.isEnded) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _button(Icons.close, tr('Закрыть'), () => Navigator.of(context).maybePop()),
          if (s.outgoing && !s.answered) _button(Icons.call, tr('Перезвонить'), _redial, color: const Color(0xFF43A047)),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 16,
      children: [
        _button(s.muted ? Icons.mic_off : Icons.mic_none, s.muted ? tr('Звук выкл.') : tr('Микрофон'), s.toggleMute, on: s.muted),
        _button(s.speaker ? Icons.volume_up : Icons.volume_down, tr('Динамик'), () => s.setSpeaker(!s.speaker), on: s.speaker),
        if (s.video) ...[
          _button(s.cameraOff ? Icons.videocam_off : Icons.videocam_outlined, tr('Камера'), s.toggleCamera, on: s.cameraOff),
          _button(Icons.cameraswitch_outlined, tr('Сменить'), s.switchCamera),
        ],
        _button(Icons.call_end, tr('Завершить'), s.hangUp, color: const Color(0xFFE53935)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final remoteVideo = s.video && s.remoteVideo && s.state == CallState.active;
    const shadow = [Shadow(blurRadius: 8, color: Colors.black54)];
    return PopScope(
      canPop: s.isEnded,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_tint, Color.lerp(_tint, Colors.black, 0.75)!],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (remoteVideo)
                RTCVideoView(s.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    if (!remoteVideo) _avatar() else const SizedBox(height: 8),
                    Text(
                      s.peerName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600, shadows: shadow),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 16, shadows: shadow),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: _controls(),
                    ),
                  ],
                ),
              ),
              if (s.video && !s.cameraOff && s.state != CallState.ringing && !s.isEnded)
                Positioned(
                  right: 16,
                  top: MediaQuery.paddingOf(context).top + 16,
                  width: 110,
                  height: 160,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: RTCVideoView(s.localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
