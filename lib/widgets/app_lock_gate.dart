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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLock.lockOnStart(widget.db);
  }

  @override
  void dispose() {
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
            if (locked) Positioned.fill(child: _LockScreen(db: widget.db)),
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
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 72,
            height: 72,
            child: TextButton(
              style: TextButton.styleFrom(shape: const CircleBorder(), backgroundColor: theme.colorScheme.surfaceContainerHighest),
              onPressed: onTap,
              child: icon != null ? Icon(icon) : Text(label, style: theme.textTheme.headlineSmall),
            ),
          ),
        );
    // Фон экрана блокировки — обои приложения под лёгким затемнением: за системным окном
    // отпечатка не пустота, а привычный фон.
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: AppBackdrop(
        kind: 'home',
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor.withValues(alpha: 0.45),
          child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
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
          ),
        ),
      ),
        ),
      ),
    );
  }
}
