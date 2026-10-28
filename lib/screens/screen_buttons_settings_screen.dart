import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../models/home_tab_specs.dart';
import '../services/demo_mode.dart';
import '../services/local_db_service.dart';
import '../services/screen_buttons.dart';
import '../voice/voice_control.dart';
import '../widgets/glass_pill.dart';

/// «Кнопки на экране»: одна кнопка поверх всех страниц, из неё веером раскрываются включённые быстрые кнопки.
class ScreenButtonsSettingsScreen extends StatelessWidget {
  final LocalDbService db;
  const ScreenButtonsSettingsScreen({super.key, required this.db});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Кнопки на экране'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: ScreenButtons.on,
            builder: (_, on, __) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Кнопки на экране')),
              subtitle: Text(tr(
                  'Одна круглая кнопка поверх всех страниц. Нажмите её — раскроется веер из быстрых кнопок, которые вы включили ниже. Если включена только одна, веера нет: кнопка сразу делает своё дело.')),
              value: on,
              onChanged: (v) => ScreenButtons.setOn(db, v),
            ),
          ),
          const Divider(height: 24),
          Text(tr('Что показывать в веере'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          ValueListenableBuilder<bool>(
            valueListenable: DemoMode.enabled,
            builder: (_, v, __) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.rate_review_outlined),
              title: Text(tr('Отзыв')),
              subtitle: Text(tr('Написать отзыв о приложении с любой страницы')),
              value: v,
              onChanged: (x) => DemoMode.set(db, x),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: VoiceSettings.enabled,
            builder: (_, v, __) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.mic_none),
              title: Text(tr('Голосовое управление')),
              subtitle: Text(tr('Команды голосом на любой странице')),
              value: v,
              onChanged: (x) => VoiceSettings.setEnabled(db, x),
            ),
          ),
          ValueListenableBuilder<List<String>>(
            valueListenable: ScreenButtons.tabs,
            builder: (_, chosen, __) => Column(children: [
              for (final id in ScreenButtons.candidates)
                if (!ScreenButtons.suppressed.contains(id))
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(homeTabSpecs[id]!.icon),
                    title: Text(tr(homeTabSpecs[id]!.label)),
                    subtitle: Text(tr('Раздел с рабочего стола — быстрый доступ')),
                    value: chosen.contains(id),
                    onChanged: (x) => ScreenButtons.setTab(db, id, x),
                  ),
            ]),
          ),
        ],
      ),
    );
  }
}
