import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Вид перехода между экранами.
enum AnimType {
  dissolve, // старое растворяется (с размытием) в фон, новое появляется из фона
  scatter, // плитки разлетаются к ближайшему краю экрана
  horizontal, // старое уходит влево, новое приезжает справа поверх
  vertical, // то же по вертикали
  zoom, // новое «наплывает» из глубины, старое отдаляется
  fade, // простое перекрёстное затухание
  morph, // плитка раскрывается в экран раздела, остальные разлетаются от неё
}

/// Настройки анимаций (раздел «Внешний вид»): вкл/выкл, скорость, тип.
/// Хранятся в color_prefs, читаются один раз при старте.
class AnimSettings {
  static bool enabled = !kIsWeb;
  static double speed = 1.0; // 0.5 — медленнее, 2 — быстрее
  static AnimType type = AnimType.horizontal;
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static String? _get(dynamic db, String k) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void load(dynamic db) {
    try {
      final on = _get(db, 'anim_on');
      if (on != null) enabled = on == '1';
      speed = (double.tryParse(_get(db, 'anim_speed') ?? '') ?? 1.0).clamp(0.5, 4.0).toDouble();
      final t = _get(db, 'anim_type');
      type = AnimType.values.where((e) => e.name == t).firstOrNull ?? type;
    } catch (_) {}
  }

  static void save(dynamic db, {bool? on, double? spd, AnimType? t}) {
    void put(String k, String v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [k, v]);
    if (on != null) {
      enabled = on;
      put('anim_on', on ? '1' : '0');
    }
    if (spd != null) {
      speed = spd;
      put('anim_speed', '$spd');
    }
    if (t != null) {
      type = t;
      put('anim_type', t.name);
    }
    revision.value++;
  }

  static String label(AnimType t) => switch (t) {
        AnimType.dissolve => 'Растворение',
        AnimType.scatter => 'Разброс',
        AnimType.horizontal => 'Горизонт',
        AnimType.vertical => 'Вертикаль',
        AnimType.zoom => 'Наплыв',
        AnimType.fade => 'Затухание',
        AnimType.morph => 'Превращение',
      };
}

/// Один построитель на все экраны: он и «приводит» новый экран (animation),
/// и «уводит» старый (secondaryAnimation) — так выходит ощущение одной страницы.
class AppTransitions extends PageTransitionsBuilder {
  const AppTransitions();

  @override
  Duration get transitionDuration =>
      AnimSettings.enabled ? Duration(milliseconds: (320 / AnimSettings.speed).round()) : Duration.zero;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  static Widget _blur(double sigma, Widget child) => sigma < 0.5
      ? child
      : ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal), child: child);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (!AnimSettings.enabled) return child;
    final type = AnimSettings.type;
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondaryAnimation]),
      child: child,
      builder: (ctx, child) {
        final size = MediaQuery.sizeOf(ctx);
        final i = Curves.easeOutCubic.transform(animation.value); // 0 → 1: этот экран приходит
        final o = Curves.easeOutCubic.transform(secondaryAnimation.value); // 0 → 1: этот экран уходит под новый
        Widget w = child!;
        switch (type) {
          case AnimType.dissolve:
            w = Opacity(opacity: (i * (1 - o)).clamp(0.0, 1.0), child: _blur(12 * (1 - i) + 12 * o, w));
          case AnimType.scatter:
            // плитки сами разлетаются (см. HomeTileGrid); экран целиком: наплыв + затухание
            w = Opacity(
                opacity: (i * (1 - math.max(0.0, o - 0.6) / 0.4)).clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.94 + 0.06 * i, child: w));
          case AnimType.horizontal:
            w = Transform.translate(offset: Offset(size.width * (1 - i) - size.width * 0.28 * o, 0), child: w);
          case AnimType.vertical:
            w = Transform.translate(offset: Offset(0, size.height * (1 - i) - size.height * 0.2 * o), child: w);
          case AnimType.zoom:
            w = Opacity(
                opacity: (i * (1 - o)).clamp(0.0, 1.0),
                child: Transform.scale(scale: (0.88 + 0.12 * i) * (1 + 0.08 * o), child: w));
          case AnimType.morph: // обычные экраны (не с плитки) — как наплыв
            w = Opacity(
                opacity: (i * (1 - o)).clamp(0.0, 1.0),
                child: Transform.scale(scale: (0.88 + 0.12 * i) * (1 + 0.08 * o), child: w));
          case AnimType.fade:
            w = Opacity(opacity: (i * (1 - o)).clamp(0.0, 1.0), child: w);
        }
        return w;
      },
    );
  }
}

/// Запоминает, какую плитку нажали (где она на экране) — от этого зависит
/// «превращение»: плитка раскрывается из своего места, остальные разлетаются.
class TileOpen {
  static final Map<String, BuildContext> contexts = {};
  static String? id;
  static Rect? rect;

  static void capture(String tileId) {
    id = tileId;
    rect = null;
    final box = contexts[tileId]?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      rect = box.localToGlobal(Offset.zero) & box.size;
    }
  }
}

/// Маршрут «превращения»: плитка (цвет, значок) растёт из своего места до
/// всего экрана и становится фоном раздела, раздел проявляется поверх.
class MorphRoute<T> extends PageRouteBuilder<T> {
  MorphRoute({required Widget page, required IconData icon, required Rect from})
      : super(
          opaque: false,
          transitionDuration: Duration(milliseconds: (420 / AnimSettings.speed).round()),
          reverseTransitionDuration: Duration(milliseconds: (360 / AnimSettings.speed).round()),
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (ctx, anim, sec, child) {
            final t = Curves.easeInOutCubic.transform(anim.value);
            if (anim.isCompleted) return child;
            final theme = Theme.of(ctx);
            final screen = MediaQuery.sizeOf(ctx);
            final rect = Rect.lerp(from, Offset.zero & screen, t)!;
            final tileColor = theme.colorScheme.surfaceContainerHigh;
            final color = Color.lerp(tileColor, theme.scaffoldBackgroundColor, t)!;
            final iconSize = (from.shortestSide * 0.45) + (screen.shortestSide * 0.85 - from.shortestSide * 0.45) * t;
            final iconColor = Color.lerp(theme.colorScheme.primary, theme.colorScheme.primary.withValues(alpha: 0), t)!;
            return Stack(children: [
              Positioned.fromRect(
                rect: rect,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16 * (1 - t))),
                  child: Center(child: Icon(icon, size: iconSize, color: iconColor)),
                ),
              ),
              // сам раздел проявляется во второй половине превращения
              Opacity(opacity: Curves.easeIn.transform(((anim.value - 0.45) / 0.55).clamp(0.0, 1.0)), child: child),
            ]);
          },
        );
}
