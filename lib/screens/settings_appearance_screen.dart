import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/personalization_view_model.dart';
import 'color_personalization_screen.dart';

/// "Внешний вид" — язык интерфейса и цветовые настройки, вынесены из
/// общего списка настроек в отдельную папку (решение пользователя:
/// распределить настройки по назначению вместо одного длинного списка).
class SettingsAppearanceScreen extends StatelessWidget {
  const SettingsAppearanceScreen({super.key});

  static const _languages = [
    (null, 'Системный'),
    ('ru', 'Русский'),
    ('en', 'English'),
  ];

  Future<void> _pickLanguage(BuildContext context, PersonalizationViewModel personalization) async {
    final picked = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (code, label) in _languages)
              ListTile(
                title: Text(label),
                trailing: personalization.localeCode == code ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(code ?? ''),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    personalization.setLocaleCode(picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final personalization = context.watch<PersonalizationViewModel>();
    final currentLabel = _languages.firstWhere((l) => l.$1 == personalization.localeCode).$2;

    return Scaffold(
      appBar: AppBar(title: const Text('Внешний вид')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: const Text('Язык'),
            subtitle: Text(currentLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, personalization),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Цветовые настройки'),
            subtitle: const Text('Тема интерфейса, бумага, яблоко, кольца, пробоины'),
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
