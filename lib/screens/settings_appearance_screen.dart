import '../logic/friendly_error.dart';
import '../theme/app_transitions.dart';
import '../widgets/home_tabs_bar.dart' show TileStyle;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../i18n/i18n.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import '../widgets/glass_pill.dart';
import '../widgets/settings_draft_scope.dart';
import '../widgets/splash_gate.dart';
import 'color_personalization_screen.dart';

/// "Внешний вид" — язык интерфейса и цветовые настройки, вынесены из
/// общего списка настроек в отдельную папку (решение пользователя:
/// распределить настройки по назначению вместо одного длинного списка).
class SettingsAppearanceScreen extends StatelessWidget {
  const SettingsAppearanceScreen({super.key});

  static String languageLabel(String? code) => switch (code) {
        null => tr('Системный'),
        'ru' => tr('Русский'),
        _ => I18n.builtIn[code] ?? I18n.downloadable[code] ?? code,
      };

  /// Встроенные языки — сразу; остальные сначала скачиваются (словарь
  /// небольшой, из репозитория) и дальше живут на устройстве.
  static Future<void> pickLanguage(
      BuildContext context, PersonalizationViewModel personalization) async {
    final db = context.read<AppDataStore>().db;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final code in <String?>[null, 'ru', ...I18n.builtIn.keys])
              ListTile(
                title: Text(languageLabel(code)),
                trailing: personalization.localeCode == code
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(ctx).pop(code ?? ''),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(tr('Ещё языки — скачиваются'),
                  style: Theme.of(ctx).textTheme.labelMedium),
            ),
            for (final code in I18n.downloadable.keys)
              ListTile(
                title: Text(languageLabel(code)),
                trailing: personalization.localeCode == code
                    ? const Icon(Icons.check)
                    : (I18n.isDownloaded(db, code)
                        ? null
                        : const Icon(Icons.download_outlined)),
                onTap: () => Navigator.of(ctx).pop(code),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (I18n.downloadable.containsKey(picked) &&
        !I18n.isDownloaded(db, picked)) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text(tr('Скачиваю перевод…'))));
      try {
        await I18n.download(db, picked);
      } catch (e) {
        messenger.showSnackBar(SnackBar(
            content: Text(tr(
                'Не удалось скачать перевод: {e}', {'e': friendlyError(e)}))));
        return;
      }
    }
    personalization.setLocaleCode(picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationViewModel>();

    final topInset = MediaQuery.paddingOf(context).top;
    return SettingsDraftScope(
      db: context.read<AppDataStore>().db,
      onRestored: () {
        personalization.loadFromDb();
        final db = context.read<AppDataStore>().db;
        AnimSettings.load(db);
        AnimSettings.revision.value++;
      },
      child: Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Внешний вид'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [Builder(builder: (ctx) => SettingsDraftScope.confirmButton(ctx, tooltip: tr('Сохранить')))],
      ),
      body: ListView(
        padding: EdgeInsets.only(top: topInset + GlassHeader.height),
        children: [
          // Видео-заставка при запуске (звук играет на Android и компьютере;
          // в браузере без звука — так требуют браузеры).
          // ---- Плитки главного экрана ----
          StatefulBuilder(
            builder: (ctx, setS) {
              final db = context.read<AppDataStore>().db;
              final glass = TileStyle.isGlass(db);
              return Column(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.blur_on),
                  title: Text(tr('Плитки-«стекло»')),
                  subtitle: Text(tr('Прозрачные плитки главного экрана')),
                  value: glass,
                  onChanged: (v) => setS(() => TileStyle.setGlass(db, v)),
                ),
                ListTile(
                  enabled: glass,
                  leading: const Icon(Icons.opacity),
                  title: Text(tr('Плотность «стекла»')),
                  subtitle: Slider(
                    min: 0.2,
                    max: 2.0,
                    value: TileStyle.alpha,
                    onChanged: glass ? (v) => setS(() => TileStyle.setAlpha(db, v)) : null,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.layers_outlined),
                  title: Text(tr('Тень плиток (объём)')),
                  subtitle: Slider(
                    min: 0,
                    max: 2.0,
                    value: TileStyle.shadow,
                    onChanged: (v) => setS(() => TileStyle.setShadow(db, v)),
                  ),
                ),
              ]);
            },
          ),
          const Divider(height: 1),
          // ---- Анимации переходов между экранами ----
          StatefulBuilder(
            builder: (ctx, setS) {
              final db = context.read<AppDataStore>().db;
              final on = AnimSettings.enabled;
              return Column(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.animation),
                  title: Text(tr('Анимации переходов')),
                  subtitle: Text(tr('Плавные переходы между экранами')),
                  value: on,
                  onChanged: (v) => setS(() => AnimSettings.save(db, on: v)),
                ),
                ListTile(
                  enabled: on,
                  leading: const Icon(Icons.swap_horiz),
                  title: Text(tr('Тип перехода')),
                  trailing: DropdownButton<AnimType>(
                    value: AnimSettings.type,
                    onChanged: on ? (t) => setS(() => AnimSettings.save(db, t: t)) : null,
                    items: [
                      for (final t in AnimType.values) DropdownMenuItem(value: t, child: Text(tr(AnimSettings.label(t)))),
                    ],
                  ),
                ),
                ListTile(
                  enabled: on,
                  leading: const Icon(Icons.speed),
                  title: Text(tr('Скорость анимаций')),
                  subtitle: Slider(
                    min: 0.5,
                    max: 4.0,
                    divisions: 14,
                    label: '×${AnimSettings.speed.toStringAsFixed(2)}',
                    value: AnimSettings.speed,
                    onChanged: on ? (v) => setS(() => AnimSettings.save(db, spd: v)) : null,
                  ),
                ),
              ]);
            },
          ),
          const Divider(height: 1),
          StatefulBuilder(
            builder: (ctx, setS) => SwitchListTile(
              secondary: const Icon(Icons.movie_outlined),
              title: Text(tr('Заставка при запуске')),
              subtitle: Text(tr('Короткая анимация при запуске')),
              value: SplashGate.isOn(context.read<AppDataStore>().db),
              onChanged: (v) => setS(() => SplashGate.setOn(context.read<AppDataStore>().db, v)),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: Text(tr('Размер шрифта')),
            subtitle: Slider(
              min: 0.8,
              max: 1.4,
              divisions: 6,
              value: personalization.fontScale,
              label: '${(personalization.fontScale * 100).round()}%',
              onChanged: personalization.setFontScale,
            ),
            trailing: TextButton(
              onPressed: personalization.fontScale == 1.0
                  ? null
                  : () => personalization.setFontScale(1.0),
              child: Text(tr('Как в системе')),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr('Цветовые настройки')),
            subtitle:
                Text(tr('Тема интерфейса, бумага, яблоко, кольца, пробоины')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const ColorPersonalizationScreen()),
            ),
          ),
        ],
      ),
    ));
  }
}
