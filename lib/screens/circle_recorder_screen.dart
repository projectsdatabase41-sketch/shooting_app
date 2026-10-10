import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../widgets/glass_pill.dart';
import '../widgets/voice_bubble.dart' show formatClock;

/// Записанный «кружок».
class CircleResult {
  final XFile file;
  final int seconds;
  const CircleResult(this.file, this.seconds);
}

/// Запись «кружка» — короткого видео в круге, до [maxSeconds] секунд. Кадр
/// квадратный (круг режется при показе), качество среднее (≈480p), чтобы
/// ролик был небольшим. Возвращает [CircleResult] или `null`, если отменили.
class CircleRecorderScreen extends StatefulWidget {
  const CircleRecorderScreen({super.key});

  static const int maxSeconds = 120;

  @override
  State<CircleRecorderScreen> createState() => _CircleRecorderScreenState();
}

class _CircleRecorderScreenState extends State<CircleRecorderScreen> {
  List<CameraDescription> _cameras = const [];
  int _camIndex = 0;
  CameraController? _controller;
  String? _error;
  bool _recording = false;
  bool _finishing = false;
  int _elapsed = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init({CameraLensDirection prefer = CameraLensDirection.front}) async {
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) throw StateError(tr('Камера не найдена'));
      _camIndex = _cameras.indexWhere((c) => c.lensDirection == prefer);
      if (_camIndex < 0) _camIndex = 0;
      await _open(_cameras[_camIndex]);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _open(CameraDescription cam) async {
    final old = _controller;
    final c = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: true,
      imageFormatGroup: kIsWeb ? null : ImageFormatGroup.yuv420,
    );
    await c.initialize();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _controller = c);
    await old?.dispose();
  }

  Future<void> _flip() async {
    if (_recording || _cameras.length < 2) return;
    final next = (_camIndex + 1) % _cameras.length;
    _camIndex = next;
    try {
      await _open(_cameras[next]);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _start() async {
    final c = _controller;
    if (c == null || _recording) return;
    try {
      await c.startVideoRecording();
      setState(() {
        _recording = true;
        _elapsed = 0;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed++);
        if (_elapsed >= CircleRecorderScreen.maxSeconds) _finish(send: true);
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _finish({required bool send}) async {
    final c = _controller;
    if (c == null || !_recording || _finishing) return;
    _finishing = true;
    _ticker?.cancel();
    try {
      final file = await c.stopVideoRecording();
      final seconds = _elapsed;
      if (!mounted) return;
      Navigator.of(context).pop(send && seconds >= 1 ? CircleResult(file, seconds) : null);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = _controller;
    final d = (MediaQuery.sizeOf(context).shortestSide * 0.82).clamp(200.0, 360.0);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Закрыть'))),
                  ]),
                ),
              )
            : Column(
                children: [
                  const Spacer(),
                  SizedBox(
                    width: d + 12,
                    height: d + 12,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: d + 12,
                          height: d + 12,
                          child: CircularProgressIndicator(
                            value: _recording ? _elapsed / CircleRecorderScreen.maxSeconds : 0,
                            strokeWidth: 4,
                            color: Colors.redAccent,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                        ClipOval(
                          child: SizedBox(
                            width: d,
                            height: d,
                            child: c == null || !c.value.isInitialized
                                ? const Center(child: CircularProgressIndicator())
                                : FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: d,
                                      height: d * c.value.aspectRatio,
                                      child: CameraPreview(c),
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _recording
                        ? '${formatClock(_elapsed)} / ${formatClock(CircleRecorderScreen.maxSeconds)}'
                        : tr('Кружок до {m} мин', {'m': CircleRecorderScreen.maxSeconds ~/ 60}),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        GlassCircleButton(
                          size: 52,
                          icon: const Icon(Icons.close),
                          tooltip: tr('Отмена'),
                          onTap: () async {
                            if (_recording) {
                              await _finish(send: false);
                            } else if (mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
                        GestureDetector(
                          onTap: c == null || !c.value.isInitialized
                              ? null
                              : (_recording ? () => _finish(send: true) : _start),
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                            alignment: Alignment.center,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: _recording ? 28 : 58,
                              height: _recording ? 28 : 58,
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(_recording ? 6 : 29),
                              ),
                            ),
                          ),
                        ),
                        GlassCircleButton(
                          size: 52,
                          icon: Icon(Icons.cameraswitch_outlined, color: _recording ? cs.outline : null),
                          tooltip: tr('Сменить камеру'),
                          onTap: _recording || _cameras.length < 2 ? null : _flip,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
