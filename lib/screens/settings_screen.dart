import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/share_token_service.dart';
import '../services/sync_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../state/personalization_view_model.dart';
import '../widgets/section_header.dart';
import 'import_screen.dart';
import 'ai_settings_screen.dart';
import 'color_personalization_screen.dart';
import 'connect_screen.dart';

/// Настройки (раздел 9 ТЗ).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _syncing = false;
  String? _syncMessage;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final cs = Theme.of(context).colorScheme;
    final bothRoles = store.isAthlete && store.isCoach;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionHeader(
              title: 'Оформление',
              subtitle: 'Тема интерфейса. Цвета самой мишени настраиваются отдельно.',
            ),
          ),
          const _ThemeModeSelector(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Персонализация цвета мишени'),
            subtitle: const Text('Бумага, яблоко, кольца, пробоины'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ColorPersonalizationScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Ассистент по результатам'),
            subtitle: const Text('Ключ OpenRouter, модели, справочные материалы'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Импорт тренировок'),
            subtitle: const Text('Из файла: координаты, результаты, показатели прибора'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ImportScreen()),
            ),
          ),
          const Divider(height: 24),
          if (bothRoles)
            SwitchListTile(
              title: const Text('Режим работы: тренер'),
              subtitle: Text(store.workMode == WorkMode.coach ? 'Тренер' : 'Спортсмен'),
              value: store.workMode == WorkMode.coach,
              onChanged: (v) {
                store.workMode = v ? WorkMode.coach : WorkMode.athlete;
                store.saveSettings();
                setState(() {});
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SectionHeader(
              title: 'Хранение',
              subtitle: 'Что держать на устройстве, а что только в облаке',
            ),
          ),
          // Три состояния вместо одного ползунка: «только облако»,
          // «последние N» и «всё на устройстве». Ползунок сам по себе
          // не отвечал на главный вопрос — держать ли данные локально
          // вообще.
          SwitchListTile(
            title: const Text('Хранить только в облаке'),
            subtitle: const Text('На устройстве не остаётся ничего'),
            value: store.storageKeepCount == 0,
            onChanged: (v) {
              store.storageKeepCount = v ? 0 : 200;
              store.saveSettings();
              setState(() {});
            },
          ),
          if (store.storageKeepCount != 0) ...[
            SwitchListTile(
              title: const Text('Хранить всё на устройстве'),
              subtitle: const Text('Ничего не вытесняется'),
              value: store.storageKeepCount >= AppDataStore.keepAll,
              onChanged: (v) {
                store.storageKeepCount = v ? AppDataStore.keepAll : 200;
                store.saveSettings();
                setState(() {});
              },
            ),
            if (store.storageKeepCount < AppDataStore.keepAll)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextFormField(
                  initialValue: '${store.storageKeepCount}',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Сколько тренировок держать на устройстве',
                    helperText: 'Остальные — только в облаке',
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n == null || n <= 0) return;
                    store.storageKeepCount = n;
                    store.saveSettings();
                  },
                ),
              ),
          ],
          const Divider(height: 24),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SectionHeader(
              title: 'Синхронизация',
              subtitle: 'Облако — резервная копия. Без автоматики, без «только Wi-Fi».',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _syncing ? null : () => _syncNow(context),
                  icon: _syncing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Синхронизировать сейчас'),
                ),
                if (_syncMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_syncMessage!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          const _ShareTokensSection(),
          const Divider(height: 24),
          ListTile(
            leading: Icon(Icons.logout, color: cs.error),
            title: Text('Отключиться', style: TextStyle(color: cs.error)),
            onTap: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const ConnectScreen()),
                (route) => false,
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    final store = context.read<AppDataStore>();
    final sync = SyncService(DemoSupabaseService());
    try {
      await sync.syncNow(store.unsyncedSessions);
      setState(() => _syncMessage = 'Готово (демо — реального облака ещё нет)');
    } catch (e) {
      setState(() => _syncMessage = 'Синхронизация недоступна: подключение к Supabase — следующий этап (раздел 12 ТЗ п.1)');
    } finally {
      setState(() => _syncing = false);
    }
  }
}

/// Переключатель светлой/тёмной темы интерфейса.
///
/// Значение живёт в `PersonalizationViewModel` (та же key-value таблица
/// `color_prefs`), поэтому переживает перезапуск. "Система" — значение
/// по умолчанию: приложение следует настройке ОС.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PersonalizationViewModel>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('Система'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Светлая'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Тёмная'),
            ),
          ],
          selected: {vm.themeMode},
          showSelectedIcon: false,
          onSelectionChanged: (set) => vm.setThemeMode(set.first),
        ),
      ),
    );
  }
}

class _ShareTokensSection extends StatefulWidget {
  const _ShareTokensSection();

  @override
  State<_ShareTokensSection> createState() => _ShareTokensSectionState();
}

class _ShareTokensSectionState extends State<_ShareTokensSection> {
  String? _lastCreatedToken;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final service = ShareTokenService(
      readGrants: () => store.shareGrants,
      persistGrant: (grant) async {
        store.db.db.execute(
          'INSERT INTO share_grants (id, token_hash, athlete_label, created_at) VALUES (?, ?, ?, ?)',
          [grant.id, grant.tokenHash, grant.athleteLabel, grant.createdAt.toIso8601String()],
        );
        store.shareGrants = [...store.shareGrants, grant];
      },
      persistRevoke: (id, revokedAt) async {
        store.db.db.execute('UPDATE share_grants SET revoked_at = ? WHERE id = ?', [revokedAt.toIso8601String(), id]);
        store.shareGrants = store.shareGrants.where((g) => g.id != id).toList();
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SectionHeader(
            title: 'Доступ тренерам',
            subtitle: 'Токены на просмотр вашего дневника',
          ),
        ),
        if (_lastCreatedToken != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              // Предупреждающая карточка: янтарный контейнер темы вместо
              // прежнего хардкода Colors.amber.shade50, который в тёмной
              // теме давал светлую плашку со светлым текстом.
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: Theme.of(context).colorScheme.onSecondaryContainer),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Токен показывается только один раз',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _lastCreatedToken!,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ...store.shareGrants.map((g) => ListTile(
              title: Text(g.athleteLabel.isEmpty ? 'Токен ${g.id.substring(0, 6)}' : g.athleteLabel),
              subtitle: Text('Создан ${g.createdAt.toLocal()}'),
              trailing: TextButton(
                onPressed: () async {
                  await service.revoke(g.id);
                  setState(() {});
                },
                child: const Text('Отозвать'),
              ),
            )),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Создать токен'),
            onPressed: () async {
              final token = await service.createToken();
              setState(() => _lastCreatedToken = token);
            },
          ),
        ),
      ],
    );
  }
}
