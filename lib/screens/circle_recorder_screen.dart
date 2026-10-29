import 'dart:async';
import 'dart:math' as math;

import '../widgets/selfie_light.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/demo_mode.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../widgets/glass_pill.dart';
import '../widgets/splash_gate.dart' show NexusPulse;
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
  /// Запись начинается сама, как только камера готова (кнопка в чате зажата).
  final bool autoStart;

  /// Сигнал «кнопку отпустили»: запись завершается и отправляется (или, если камера ещё не готова, экран закрывается).
  final ValueListenable<int>? finishSignal;
  const CircleRecorderScreen(
      {super.key, this.autoStart = false, this.finishSignal});

  static const int maxSeconds = 120;

  /// Продление: за 10 с до конца появляется кнопка «+2 мин» — кружок остаётся одним, только длиннее.
  static const int extendSeconds = 120;
  static const int hardLimit = 600;

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
  final _light = SelfieLightState();
  bool _torch = false;
  bool get _isFront =>
      _cameras.isNotEmpty &&
      _cameras[_camIndex].lensDirection == CameraLensDirection.front;

  Future<void> _toggleLight() async {
    if (_isFront) {
      _light.toggle(); // сразу, без окон; яркость — свайпом вверх/вниз, теплота — вправо/влево
      return;
    }
    final c = _controller;
    if (c == null) return;
    try {
      await c.setFlashMode(_torch ? FlashMode.off : FlashMode.torch);
      setState(() => _torch = !_torch);
    } catch (_) {}
  }

  // Зум двумя пальцами (щипок) на кружке: уровень камеры от минимума до максимума, сбрасывается при смене камеры.
  double _zoom = 1, _minZoom = 1, _maxZoom = 1;
  final Map<int, Offset> _ptr = {};
  double _pinchDist = 1, _pinchZoom = 1;

  bool _hd = false; // HD: видео выше разрешением (тяжелее); меняется до начала записи

  bool _switching =
      false; // идёт смена камеры — картинку прячем, чтобы не мелькал кадр «вверх ногами»
  int _elapsed = 0;
  int _limit = CircleRecorderScreen.maxSeconds;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.finishSignal?.addListener(_onSignal);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _init().then((_) {
      if (widget.autoStart && !_released && mounted) _start();
    });
  }

  bool _released = false;

  void _onSignal() {
    _released = true;
    if (_recording) {
      _finish(send: true);
    } else if (mounted && !_finishing) {
      Navigator.of(context)
          .pop(); // отпустили до начала записи — ничего не записано
    }
  }

  Future<void> _init(
      {CameraLensDirection prefer = CameraLensDirection.front}) async {
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
      _hd ? ResolutionPreset.high : ResolutionPreset.medium,
      enableAudio: true,
      imageFormatGroup: kIsWeb ? null : ImageFormatGroup.yuv420,
    );
    await c.initialize();
    if (!mounted) {
      await c.dispose();
      return;
    }
    try {
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (_) {}
    try {
      _minZoom = await c.getMinZoomLevel();
      _maxZoom = await c.getMaxZoomLevel();
      _zoom = _minZoom;
      await c.setZoomLevel(_zoom);
    } catch (_) {
      _minZoom = _maxZoom = _zoom = 1; // на этой камере зум недоступен
    }
    setState(() => _controller = c);
    await old?.dispose();
  }

  void _pinchDown(PointerDownEvent e) {
    _ptr[e.pointer] = e.localPosition;
    if (_ptr.length == 2) {
      final p = _ptr.values.toList();
      _pinchDist = (p[0] - p[1]).distance.clamp(1.0, 5000.0);
      _pinchZoom = _zoom;
    }
  }

  Future<void> _pinchMove(PointerMoveEvent e) async {
    if (!_ptr.containsKey(e.pointer)) return;
    _ptr[e.pointer] = e.localPosition;
    final c = _controller;
    if (_ptr.length < 2 || c == null || _maxZoom <= _minZoom) return;
    final p = _ptr.values.take(2).toList();
    final z = (_pinchZoom * (p[0] - p[1]).distance / _pinchDist)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    if ((z - _zoom).abs() < 0.02) return;
    setState(() => _zoom = z);
    try {
      await c.setZoomLevel(z);
    } catch (_) {}
  }

  Future<void> _flip() async {
    if (_cameras.length < 2) return;
    final next = (_camIndex + 1) % _cameras.length;
    // Свет переходит вместе с камерой: подсветка экрана на селфи ⇄ фонарик на основной.
    final lightWasOn = _isFront ? _light.on : _torch;
    _camIndex = next;
    setState(() {
      _switching = true;
      _torch = false;
    });
    if (_light.on) _light.turnOff();
    try {
      final c = _controller;
      if (_recording && c != null) {
        // камеру можно сменить прямо во время записи (запись продолжается одним роликом)
        await c.setDescription(_cameras[next]);
        if (mounted) setState(() {});
      } else {
        await _open(_cameras[next]);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
    if (lightWasOn && mounted) {
      if (_isFront) {
        _light.turnOn();
      } else {
        try {
          await _controller?.setFlashMode(FlashMode.torch);
          if (mounted) setState(() => _torch = true);
        } catch (_) {}
      }
    }
    // пока камера не выдала нормальный кадр (и не закончится разворот картинки) — она скрыта под заставкой
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _switching = false);
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
        if (_elapsed >= _limit) _finish(send: true);
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
      final file = await c.stopVideoRecording().timeout(const Duration(seconds: 8));
      final seconds = _elapsed;
      if (!mounted) return;
      Navigator.of(context).pop(send && seconds >= 1 ? CircleResult(file, seconds) : null);
    } catch (e) {
      // Камера не дала остановить запись: не зависаем с мёртвыми кнопками — закрываем экран (запись не сохранена).
      DemoMode.sendError('Circle stop', e);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    widget.finishSignal?.removeListener(_onSignal);
    _ticker?.cancel();
    SystemChrome.setPreferredOrientations(const []); // снова любая ориентация (как у приложения)
    _controller?.dispose();
    _light.release();
    _light.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final d =
        (MediaQuery.sizeOf(context).shortestSide * 0.82).clamp(200.0, 360.0);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        // подсветка экрана по краям (фронтальная камера) — под интерфейсом
        SelfieLightOverlay(light: _light),
        Positioned.fill(child: SelfieLightGestures(light: _light, child: const SizedBox.expand())),
        SafeArea(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 16),
                      FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(tr('Закрыть'))),
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
                          ListenableBuilder(
                            listenable: _light,
                            builder: (_, __) => !(_light.on && _light.rgb && _isFront)
                                ? const SizedBox.shrink()
                                : Positioned(
                                    left: -26,
                                    right: -26,
                                    top: -26,
                                    bottom: -26,
                                    child: HueRing(hue: _light.hue, onChanged: (h) => _light.update(() => _light.hue = h)),
                                  ),
                          ),
                          SizedBox(
                            width: d + 12,
                            height: d + 12,
                            child: CircularProgressIndicator(
                              value: _recording
                                  ? _elapsed / _limit
                                  : 0,
                              strokeWidth: 4,
                              color: Colors.redAccent,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          Listener(
                            onPointerDown: _pinchDown,
                            onPointerMove: _pinchMove,
                            onPointerUp: (e) => _ptr.remove(e.pointer),
                            onPointerCancel: (e) => _ptr.remove(e.pointer),
                            child: ClipOval(
                              child: SizedBox(
                                width: d,
                                height: d,
                                child: _switching
                                    ? ColoredBox(
                                        color: Colors.black,
                                        child: Center(
                                            child: NexusPulse(size: d * 0.6)))
                                    : c == null || !c.value.isInitialized
                                        ? const Center(
                                            child: CircularProgressIndicator())
                                        : AnimatedOpacity(
                                            opacity: _switching ? 0 : 1,
                                            duration: const Duration(
                                                milliseconds: 150),
                                            child: FittedBox(
                                              fit: BoxFit.cover,
                                              child: SizedBox(
                                                width: d,
                                                height: d * c.value.aspectRatio,
                                                child: CameraPreview(c),
                                              ),
                                            )),
                              ),
                            ),
                          ),
                          if (_zoom > _minZoom + 0.05)
                            Positioned(
                              bottom: 10,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 2),
                                decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(12)),
                                child: Text(
                                    '×${(_zoom / _minZoom).toStringAsFixed(1)}',
                                    style:
                                        const TextStyle(color: Colors.white)),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _recording
                          ? '${formatClock(_elapsed)} / ${formatClock(_limit)}'
                          : tr('Кружок до {m} мин',
                              {'m': CircleRecorderScreen.maxSeconds ~/ 60}),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (_recording && _limit - _elapsed <= 10 && _limit < CircleRecorderScreen.hardLimit)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.tonalIcon(
                          onPressed: () => setState(() => _limit = math.min(_limit + CircleRecorderScreen.extendSeconds, CircleRecorderScreen.hardLimit)),
                          icon: const Icon(Icons.add),
                          label: Text(tr('Продлить на {m} мин', {'m': CircleRecorderScreen.extendSeconds ~/ 60})),
                        ),
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
                                : (_recording
                                    ? () => _finish(send: true)
                                    : _start),
                            child: Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 4),
                              ),
                              alignment: Alignment.center,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: _recording ? 28 : 58,
                                height: _recording ? 28 : 58,
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(
                                      _recording ? 6 : 29),
                                ),
                              ),
                            ),
                          ),
                          // Во время записи качество не сменить (камера пересоздаётся) — кнопка гаснет.
                          Opacity(
                            opacity: _recording ? 0.35 : 1,
                            child: GlassCircleButton(
                            size: 52,
                            icon: Text('HD', style: TextStyle(fontWeight: FontWeight.w900, color: _hd ? Theme.of(context).colorScheme.primary : null)),
                            tooltip: _recording ? tr('Качество меняется до начала записи') : _hd ? tr('Высокое качество включено') : tr('Включить высокое качество (HD)'),
                            onTap: _recording
                                ? null
                                : () async {
                                    setState(() {
                                      _hd = !_hd;
                                      _switching = true;
                                    });
                                    try {
                                      await _open(_cameras[_camIndex]);
                                    } catch (_) {}
                                    if (mounted) setState(() => _switching = false);
                                  },
                          )),
                          GlassCircleButton(
                            size: 52,
                            icon: const Icon(Icons.cameraswitch_outlined),
                            tooltip: tr('Сменить камеру'),
                            onTap: _cameras.length < 2 ? null : _flip,
                          ),
                          // Свет: задняя камера — фонарик, фронтальная — подсветка экрана.
                          // Тап — включить/выключить сразу; удержание 2 с — выбор цвета (RGB) кольцом вокруг кружка.
                          HoldButton(
                            onTap: _toggleLight,
                            onHold: () {
                              if (!_isFront) return;
                              if (!_light.on) _light.turnOn();
                              _light.update(() => _light.rgb = !_light.rgb);
                            },
                            child: GlassCircleButton(
                              size: 52,
                              icon: Icon(_isFront
                                  ? Icons.wb_incandescent_outlined
                                  : (_torch
                                      ? Icons.flashlight_on
                                      : Icons.flashlight_off)),
                              tooltip: tr('Свет'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ]),
    );
  }
}
