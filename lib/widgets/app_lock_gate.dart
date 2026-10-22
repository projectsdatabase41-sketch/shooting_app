import '../theme/wallpaper.dart';
import 'splash_gate.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../i18n/i18n.dart';
import '../services/app_lock.dart';
import '../services/local_db_service.dart';
import 'app_backdrop.dart';
import 'pattern_pad.dart';

/// Закрывает приложение экраном ввода PIN / биометрии, пока оно заблокировано
/// (при запуске и после сворачивания на заданное в настройках время).
class AppLockGate extends StatefulWidget {
  final LocalDbService db;
  final Widget child;
  const AppLockGate({super.key, required this.db, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  /// Приложение уже открывали после запуска. Пока нет — содержимое (и заставка с анимацией) даже не
  /// строится: анимация входа начинается ПОСЛЕ ввода PIN / отпечатка.
  bool _everUnlocked = false;

  /// Экран ввода показан. В вебе его включаем после заставки: пока она идёт, приложение под ней уже
  /// строится и прогревается, и после ввода пароля нет задержки.
  bool _lockShown = true;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLock.lockOnStart(widget.db);
    // Обои главного экрана - в кэш заранее, пока приложение грузится.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Wallpaper.warmUp(context);
    });
    if (kIsWeb && AppLock.locked.value && SplashGate.isOn(widget.db)) {
      _everUnlocked = true; // содержимое (с заставкой) строится сразу
      _lockShown = false;
      _lockTimer = Timer(const Duration(milliseconds: SplashGate.maxMs + 80), () {
        if (mounted) setState(() => _lockShown = true);
      });
    }
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      AppLock.onPaused();
    } else if (state == AppLifecycleState.resumed) {
      AppLock.onResumed(widget.db);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AppLock.locked,
        builder: (_, locked, __) {
          if (!locked) _everUnlocked = true;
          return Stack(children: [
            // Пока заперто, содержимое не получает ни касаний, ни фокуса.
            if (_everUnlocked)
              Positioned.fill(child: ExcludeFocus(excluding: locked, child: IgnorePointer(ignoring: locked, child: widget.child))),
            if (locked && _lockShown) Positioned.fill(child: _LockScreen(db: widget.db)),
          ]);
        },
      );
}

class _LockScreen extends StatefulWidget {
  final LocalDbService db;
  const _LockScreen({required this.db});

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  String _pin = '';
  String? _error;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AppLock.lockoutLeft(widget.db) != null) setState(() {});
    });
    if (AppLock.biometricOn(widget.db) && AppLock.biometricAuto(widget.db)) WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _biometric() async {
    if (await AppLock.biometricAuth(tr('Вход в Nexus'))) AppLock.locked.value = false;
  }

  Future<void> _pattern(String seq) async {
    if (_busy || AppLock.lockoutLeft(widget.db) != null) return;
    if (seq.length < 4) {
      setState(() => _error = tr('Соедините минимум 4 точки'));
      return;
    }
    _busy = true;
    final ok = await AppLock.verify(widget.db, seq);
    _busy = false;
    if (!mounted) return;
    if (ok) {
      AppLock.locked.value = false;
    } else {
      HapticFeedback.heavyImpact();
      setState(() => _error = tr('Неверный ключ'));
    }
  }

  Future<void> _digit(String d) async {
    final len = AppLock.pinLength(widget.db);
    if (_busy || AppLock.lockoutLeft(widget.db) != null || _pin.length >= len) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    // Проверка идёт сама, когда набрана вся длина PIN (иначе неполный ввод считался бы ошибкой).
    if (_pin.length == len) {
      _busy = true;
      final ok = await AppLock.verify(widget.db, _pin);
      _busy = false;
      if (!mounted) return;
      if (ok) {
        AppLock.locked.value = false;
      } else {
        HapticFeedback.heavyImpact();
        setState(() {
          _pin = '';
          _error = tr('Неверный PIN');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = AppLock.lockoutLeft(widget.db);
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => _LockKey(label: label, icon: icon, onTap: onTap);
    final header = Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.lock_outline, size: 40),
      const SizedBox(height: 12),
      Text('Nexus', style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(AppLock.method(widget.db) == 'pattern' ? tr('Нарисуйте графический ключ') : tr('Введите PIN'), style: theme.textTheme.bodyMedium),
      const SizedBox(height: 16),
      if (AppLock.method(widget.db) == 'pin')
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < AppLock.pinLength(widget.db); i++)
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _pin.length ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
              ),
            ),
        ]),
      SizedBox(
        height: 28,
        child: Center(
          child: Text(
            left != null ? tr('Слишком много попыток. Подождите {s} с', {'s': left.inSeconds + 1}) : (_error ?? ''),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      ),
    ]);
    // Фон экрана блокировки — обои приложения под лёгким затемнением: за системным окном
    // отпечатка не пустота, а привычный фон.
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: AppBackdrop(
        kind: 'home',
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor.withValues(alpha: 0.45),
          child: SafeArea(
        // Заголовок по центру свободного места, клавиатура внизу и ещё ряд кнопок (84 px) до края.
        child: Column(children: [
          Expanded(child: Center(child: SingleChildScrollView(child: header))),
          Column(mainAxisSize: MainAxisSize.min, children: [
              if (AppLock.method(widget.db) == 'pattern') ...[
                PatternPad(onComplete: _pattern, error: _error != null),
                if (AppLock.biometricOn(widget.db))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextButton.icon(onPressed: _biometric, icon: const Icon(Icons.fingerprint), label: Text(tr('Отпечаток / лицо'))),
                  ),
              ] else ...[
              for (final row in const [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
              ])
                Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _digit(d))]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                AppLock.biometricOn(widget.db) ? key('', icon: Icons.fingerprint, onTap: _biometric) : const SizedBox(width: 84, height: 84),
                key('0', onTap: () => _digit('0')),
                key('', icon: Icons.backspace_outlined, onTap: () => setState(() {
                      if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
                    })),
              ]),
              ],
          ]),
          const SizedBox(height: 84),
        ]),
      ),
        ),
      ),
    );
  }
}

/// Круглая клавиша с объёмом (светлая грань сверху, тень снизу); свечение цвета приложения - только пока нажата.
class _LockKey extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _LockKey({required this.label, this.icon, this.onTap});

  @override
  State<_LockKey> createState() => _LockKeyState();
}

class _LockKeyState extends State<_LockKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Listener(
        onPointerDown: (_) => setState(() => _down = true),
        onPointerUp: (_) => setState(() => _down = false),
        onPointerCancel: (_) => setState(() => _down = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color.lerp(cs.surfaceContainerHighest, Colors.white, _down ? 0.04 : 0.14)!, Color.lerp(cs.surfaceContainerHighest, Colors.black, _down ? 0.1 : 0.22)!],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
            boxShadow: [
              if (_down) BoxShadow(color: cs.primary.withValues(alpha: 0.6), blurRadius: 20, spreadRadius: 2),
              BoxShadow(color: Colors.black.withValues(alpha: _down ? 0.2 : 0.45), blurRadius: _down ? 3 : 6, offset: Offset(0, _down ? 1 : 4)),
            ],
          ),
          child: SizedBox(
            width: 72,
            height: 72,
            child: TextButton(
              style: TextButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
              onPressed: widget.onTap,
              child: widget.icon != null
                  ? Icon(widget.icon, size: 36)
                  : Text(widget.label, style: theme.textTheme.headlineSmall?.copyWith(fontSize: (theme.textTheme.headlineSmall?.fontSize ?? 24) * 1.5, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}
