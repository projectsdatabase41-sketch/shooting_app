import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/modules_settings.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';

/// «Модули»: необязательные части приложения. Выключенный модуль скрыт и
/// ничего не делает в фоне.
class SettingsModulesScreen extends StatefulWidget {
  const SettingsModulesScreen({super.key});

  @override
  State<SettingsModulesScreen> createState() => _SettingsModulesScreenState();
}

class _SettingsModulesScreenState extends State<SettingsModulesScreen> {
  @override
  Widget build(BuildContext context) {
    final db = context.read<AppDataStore>().db;
    final items = <(AppModule, IconData, String, String)>[
      (
        AppModule.messenger,
        Icons.forum_outlined,
        tr('Мессенджер'),
        tr('Чаты, вызов тренера, push-уведомления')
      ),
      (
        AppModule.assistant,
        Icons.auto_awesome_outlined,
        tr('ИИ Ассистент'),
        tr('Чаты с ИИ, помощники, поиск, режим мышления')
      ),
      (
        AppModule.localAi,
        Icons.offline_bolt_outlined,
        tr('Локальный ИИ'),
        tr('Модель на самом устройстве, без интернета')
      ),
      (
        AppModule.services,
        Icons.extension_outlined,
        tr('Сервисы'),
        tr('Свои плитки: Google Диск, Supabase, любые API')
      ),
    ];
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Модули'),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + GlassHeader.height + 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              tr('Основа приложения — записи тренировок и заметки тренера. Остальное включается здесь; выключенный модуль скрыт и не работает в фоне.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final (module, icon, title, subtitle) in items)
            SwitchListTile(
              secondary: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle),
              value: ModulesSettings.isOn(db, module),
              onChanged: (v) =>
                  setState(() => ModulesSettings.set(db, module, v)),
            ),
        ],
      ),
    );
  }
}
