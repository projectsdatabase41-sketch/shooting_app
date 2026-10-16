import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/local_db_service.dart';

/// Заставка при запуске приложения: видео на чёрном фоне, пока под ним уже
/// готово приложение. Показывается один раз за запуск (смена языка и прочие
/// пересборки её не повторяют), касание пропускает. Если видео не удалось
/// запустить (нет плагина, ошибка декодера), приложение открывается сразу.
class SplashGate extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final LocalDbService? db;
  const SplashGate({super.key, required this.child, this.enabled = true, this.db});

  static bool _played = false;

  /// Настройка «Заставка при запуске» (по умолчанию включена).
  static bool isOn(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', ['splash_on']);
    return rows.isEmpty || '${rows.first['hex']}' != '0';
  }

  static void setOn(LocalDbService db, bool v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        ['splash_on', v ? '1' : '0'],
      );

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  VideoPlayerController? _c;
  bool _showing = false;
  bool _fading = false;
  Timer? _guard;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled || SplashGate._played) return;
    SplashGate._played = true;
    _showing = true;
    _start();
  }

  Future<void> _start() async {
    try {
      final c = VideoPlayerController.asset('assets/video/intro.mp4');
      _c = c;
      await c.initialize().timeout(const Duration(seconds: 6));
      if (!mounted) return;
      // В браузере звук без жеста пользователя запрещён — там играем без него.
      await c.setVolume(kIsWeb ? 0 : 1);
      c.addListener(_onTick);
      await c.play();
      setState(() {});
      // Страховка: заставка не должна зависнуть, даже если видео «застыло».
      _guard = Timer(c.value.duration + const Duration(seconds: 3), _finish);
    } catch (_) {
      _finish();
    }
  }

  void _onTick() {
    final v = _c?.value;
    if (v == null || !v.isInitialized) return;
    if (v.hasError || v.position >= v.duration) _finish();
  }

  void _finish() {
    if (!mounted || _fading || !_showing) return;
    _guard?.cancel();
    setState(() => _fading = true);
    // После плавного исчезновения освобождаем плеер.
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _showing = false);
      _c?.dispose();
      _c = null;
    });
  }

  @override
  void dispose() {
    _guard?.cancel();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showing) return widget.child;
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          ignoring: _fading,
          child: AnimatedOpacity(
            opacity: _fading ? 0 : 1,
            duration: const Duration(milliseconds: 400),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _finish, // касание пропускает заставку
              child: ColoredBox(
                color: Colors.black, // фон видео — чистый чёрный, шва нет
                child: ready
                    ? Center(
                        child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
