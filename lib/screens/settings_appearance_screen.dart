import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../i18n/i18n.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import 'color_personalization_screen.dart';

/// "Внешний вид" — язык интерфейса и цветовые настройки, вынесены из
/// общего списка настроек в отдельную папку (решение пользователя:
/// распределить настройки по назначению вместо одного длинного списка).
class SettingsAppearanceScreen extends StatelessWidget {
  const SettingsAppearanceScreen({super.key});

  static String _label(String? code) => switch (code) {
        null => tr('Системный'),
        'ru' => tr('Русский'),
        _ => I18n.builtIn[code] ?? I18n.downloadable[code] ?? code,
      };

  /// Встроенные языки — сразу; остальные сначала скачиваются (словарь
  /// небольшой, из репозитория) и дальше живут на устройстве.
  Future<void> _pickLanguage(BuildContext context, PersonalizationViewModel personalization) async {
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
                title: Text(_label(code)),
                trailing: personalization.localeCode == code ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(code ?? ''),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(tr('Ещё языки — скачиваются'), style: Theme.of(ctx).textTheme.labelMedium),
            ),
            for (final code in I18n.downloadable.keys)
              ListTile(
                title: Text(_label(code)),
                trailing: personalization.localeCode == code
                    ? const Icon(Icons.check)
                    : (I18n.isDownloaded(db, code) ? null : const Icon(Icons.download_outlined)),
                onTap: () => Navigator.of(ctx).pop(code),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (I18n.downloadable.containsKey(picked) && !I18n.isDownloaded(db, picked)) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text(tr('Скачиваю перевод…'))));
      try {
        await I18n.download(db, picked);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(tr('Не удалось скачать перевод: {e}', {'e': e}))));
        return;
      }
    }
    personalization.setLocaleCode(picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationViewModel>();
    final currentLabel = _label(personalization.localeCode);

    return Scaffold(
      appBar: AppBar(title: Text(tr('Внешний вид'))),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: Text(tr('Язык')),
            subtitle: Text(currentLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, personalization),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr('Цветовые настройки')),
            subtitle: Text(tr('Тема интерфейса, бумага, яблоко, кольца, пробоины')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ColorPersonalizationScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
