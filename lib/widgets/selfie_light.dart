import 'glass_route.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Подсветка при съёмке на фронтальную камеру: экран по краям светится как
/// виньетка. Настройки: яркость, теплота (от холодного белого к тёплому) или
/// свой цвет (RGB — оттенок ползунком).
class SelfieLightState extends ChangeNotifier {
  bool on = false;
  double brightness = 0.7; // 0..1
  double warmth = 0.4; // 0 — холодный, 1 — тёплый
  bool rgb = false;
  double hue = 200; // 0..360, только в режиме RGB

  void update(void Function() f) {
    f();
    notifyListeners();
  }

  Color get color {
    if (rgb) return HSVColor.fromAHSV(1, hue, 0.85, 1).toColor();
    // холодный белый (200,225,255) → тёплый (255,190,120)
    return Color.lerp(const Color(0xFFC8E1FF), const Color(0xFFFFBE78), warmth)!;
  }
}

/// Сама виньетка — класть поверх изображения, касания не перехватывает.
class SelfieLightOverlay extends StatelessWidget {
  final SelfieLightState light;
  const SelfieLightOverlay({super.key, required this.light});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: light,
        builder: (context, _) {
          if (!light.on) return const SizedBox.shrink();
          final c = light.color;
          return IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.95,
                  colors: [c.withValues(alpha: 0), c.withValues(alpha: 0.15 * light.brightness), c.withValues(alpha: 0.95 * light.brightness)],
                  stops: const [0.45, 0.75, 1.0],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      );
}

/// Панель настроек подсветки.
Future<void> showSelfieLightSheet(BuildContext context, SelfieLightState light) {
  return showGlassSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: light,
      builder: (ctx, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Подсветка экрана')),
              value: light.on,
              onChanged: (v) => light.update(() => light.on = v),
            ),
            Text(tr('Яркость'), style: Theme.of(ctx).textTheme.labelLarge),
            Slider(value: light.brightness, onChanged: (v) => light.update(() => light.brightness = v)),
            Row(children: [
              Expanded(child: Text(light.rgb ? tr('Цвет') : tr('Теплота'), style: Theme.of(ctx).textTheme.labelLarge)),
              TextButton.icon(
                onPressed: () => light.update(() => light.rgb = !light.rgb),
                icon: Icon(light.rgb ? Icons.wb_sunny_outlined : Icons.palette_outlined, size: 18),
                label: Text(light.rgb ? tr('Белый') : 'RGB'),
              ),
            ]),
            if (light.rgb)
              Slider(
                min: 0,
                max: 360,
                value: light.hue,
                activeColor: light.color,
                onChanged: (v) => light.update(() => light.hue = v),
              )
            else
              Slider(value: light.warmth, onChanged: (v) => light.update(() => light.warmth = v)),
          ]),
        ),
      ),
    ),
  );
}
