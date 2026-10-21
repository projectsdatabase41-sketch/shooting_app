import '../widgets/app_backdrop.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/app_lock.dart';
import '../services/local_db_service.dart';
import '../widgets/glass_pill.dart';
import '../widgets/pattern_pad.dart';

/// «Защита входа»: PIN при запуске приложения, вход по биометрии, время до повторной блокировки.
class SecuritySettingsScreen extends StatefulWidget {
  final LocalDbService db;
  const SecuritySettingsScreen({super.key, required this.db});

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  bool _bioAvailable = false;
  LocalDbService get db => widget.db;

  @override
  void initState() {
    super.initState();
    AppLock.biometricAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
  }

  /// Диалог: два раза ввести новый PIN. `null` — отмена.
  Future<String?> _askNewPin() async {
    final a = TextEditingController(), b = TextEditingController();
    String? error;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(tr('Новый PIN')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: a, autofocus: true, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: InputDecoration(labelText: tr('PIN (4–8 цифр)'))),
            TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: InputDecoration(labelText: tr('Повторите PIN'), errorText: error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: () {
                if (!AppLock.validPin(a.text)) {
                  setS(() => error = tr('От 4 до 8 цифр'));
                } else if (a.text != b.text) {
                  setS(() => error = tr('PIN не совпадает'));
                } else {
                  Navigator.pop(ctx, a.text);
                }
              },
              child: Text(tr('Сохранить')),
            ),
          ],
        ),
      ),
    );
    return r;
  }

  /// Графический ключ дважды. `null` — отмена.
  Future<String?> _askNewPattern() async {
    String? first;
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(first == null ? tr('Нарисуйте ключ') : tr('Повторите ключ')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            PatternPad(
              size: 240,
              error: error != null,
              onComplete: (seq) {
                if (!AppLock.validPattern(seq)) {
                  setS(() => error = tr('От 4 до 9 разных точек'));
                } else if (first == null) {
                  setS(() {
                    first = seq;
                    error = null;
                  });
                } else if (first == seq) {
                  Navigator.pop(ctx, seq);
                } else {
                  setS(() {
                    first = null;
                    error = tr('Не совпало, начните заново');
                  });
                }
              },
            ),
            SizedBox(height: 24, child: Text(error ?? '', style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена')))],
        ),
      ),
    );
  }

  /// Подтверждение текущим PIN (перед отключением и сменой).
  Future<bool> _confirmPin() async {
    if (AppLock.method(db) == 'pattern') {
      String? error;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: Text(tr('Текущий ключ')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              PatternPad(
                size: 240,
                error: error != null,
                onComplete: (seq) async {
                  if (await AppLock.verify(db, seq)) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setS(() => error = AppLock.lockoutLeft(db) != null ? tr('Слишком много попыток, подождите') : tr('Неверный ключ'));
                  }
                },
              ),
              SizedBox(height: 24, child: Text(error ?? '', style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена')))],
          ),
        ),
      );
      return ok == true;
    }
    final c = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(tr('Текущий PIN')),
          content: TextField(controller: c, autofocus: true, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: InputDecoration(errorText: error)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: () async {
                final good = await AppLock.verify(db, c.text);
                if (good) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } else {
                  setS(() => error = AppLock.lockoutLeft(db) != null ? tr('Слишком много попыток, подождите') : tr('Неверный PIN'));
                }
              },
              child: Text(tr('ОК')),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      // Как защищать вход: PIN или графический ключ.
      final m = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(tr('Чем защитить вход')),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'pin'), child: Text(tr('PIN-код (цифры)'))),
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'pattern'), child: Text(tr('Графический ключ'))),
          ],
        ),
      );
      if (m == null || !mounted) return;
      if (m == 'pattern') {
        final p = await _askNewPattern();
        if (p == null) return;
        await AppLock.setPattern(db, p);
      } else {
        final pin = await _askNewPin();
        if (pin == null) return;
        await AppLock.setPin(db, pin);
      }
    } else {
      if (!await _confirmPin()) return;
      AppLock.disable(db);
    }
    if (mounted) setState(() {});
  }

  Future<void> _change() async {
    if (!await _confirmPin()) return;
    if (AppLock.method(db) == 'pattern') {
      final p = await _askNewPattern();
      if (p == null) return;
      await AppLock.setPattern(db, p);
    } else {
      final pin = await _askNewPin();
      if (pin == null) return;
      await AppLock.setPin(db, pin);
    }
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Защита входа изменена'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = AppLock.isEnabled(db);
    final delay = AppLock.delaySec(db);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Защита входа'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: AppBackdrop(kind: 'settings', child: ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: Text(tr('Защита входа')),
            subtitle: Text(AppLock.isEnabled(db) ? (AppLock.method(db) == 'pattern' ? tr('Графический ключ') : tr('PIN-код')) : tr('PIN-код или графический ключ. Забытый не восстановить — придётся переустановить приложение.')),
            value: enabled,
            onChanged: _toggle,
          ),
          if (enabled) ...[
            ListTile(
              leading: const Icon(Icons.password_outlined),
              title: Text(AppLock.method(db) == 'pattern' ? tr('Сменить ключ') : tr('Сменить PIN')),
              onTap: _change,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: Text(tr('Вход по отпечатку / лицу')),
              subtitle: Text(_bioAvailable ? tr('PIN остаётся запасным способом') : tr('На этом устройстве биометрия недоступна или не настроена')),
              value: AppLock.biometricOn(db),
              onChanged: !_bioAvailable
                  ? null
                  : (v) async {
                      if (v && !await AppLock.biometricAuth(tr('Подтвердите вход по биометрии'))) return;
                      AppLock.setBiometric(db, v);
                      if (mounted) setState(() {});
                    },
            ),
            if (AppLock.biometricOn(db))
              SwitchListTile(
                secondary: const Icon(Icons.open_in_new),
                title: Text(tr('Сразу показывать окно отпечатка')),
                subtitle: Text(tr('Окно рисует сама система (снизу), заменить его нельзя. Выключено: сначала наш экран, отпечаток — по кнопке.')),
                value: AppLock.biometricAuto(db),
                onChanged: (v) {
                  AppLock.setBiometricAuto(db, v);
                  setState(() {});
                },
              ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(tr('Просить вход снова')),
              trailing: DropdownButton<int>(
                value: const [0, 30, 60, 300, 900].contains(delay) ? delay : 0,
                underline: const SizedBox.shrink(),
                onChanged: (v) {
                  if (v == null) return;
                  AppLock.setDelaySec(db, v);
                  setState(() {});
                },
                items: [
                  DropdownMenuItem(value: 0, child: Text(tr('Сразу'))),
                  DropdownMenuItem(value: 30, child: Text(tr('Через 30 с'))),
                  DropdownMenuItem(value: 60, child: Text(tr('Через 1 мин'))),
                  DropdownMenuItem(value: 300, child: Text(tr('Через 5 мин'))),
                  DropdownMenuItem(value: 900, child: Text(tr('Через 15 мин'))),
                ],
              ),
            ),
          ],
        ],
      )),
    );
  }
}
