import 'package:flutter/material.dart';

import '../finals/voice_packs.dart' show VoicePacks;
import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../services/modules_settings.dart';
import '../services/voice_pack_store.dart';
import '../widgets/glass_pill.dart';

/// id вкладки-плитки модуля «Озвучка» на главном экране (см. `HomeShell`).
const voiceTabId = 'voice';

/// Модуль озвучки финалов (владелец 24.11): выбор движка — готовый пакет /
/// ИИ в реальном времени со своим ключом / машинная озвучка телефоном, — и
/// скачивание готовых пакетов с Google Диска. Выбор движка сразу читается
/// финалом ([FinalsAnnouncer] → VoicePackStore.engineOf) — в настройки
/// финалов для этого ходить не нужно.
class VoiceModuleScreen extends StatefulWidget {
  final LocalDbService db;
  const VoiceModuleScreen({super.key, required this.db});

  @override
  State<VoiceModuleScreen> createState() => _VoiceModuleScreenState();
}

class _VoiceModuleScreenState extends State<VoiceModuleScreen> {
  LocalDbService get db => widget.db;
  String? _verifyMessage; // ответ «Проверить» для языка
  String? _verifyLang;

  @override
  void initState() {
    super.initState();
    // Каталог вшит в приложение: читается один раз, статусы файлов — затем.
    VoicePackStore.loadCatalog();
  }

  Future<void> _download(String lang) async {
    await VoicePackStore.refreshStatuses();
    final err = await VoicePackStore.download(lang);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Пакет скачан'))));
    }
  }

  Future<void> _delete(String lang) async {
    await VoicePackStore.delete(lang);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Пакет удалён'))));
    }
  }

  Future<void> _verify(String lang) async {
    final msg = await VoicePackStore.verify(lang);
    if (mounted) setState(() { _verifyMessage = msg; _verifyLang = lang; });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final moduleOn = ModulesSettings.isOn(db, AppModule.voice);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
          title: Text(tr('Озвучка'),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 32),
        children: [
          Text(
            tr('Диктор финалов. Можно говорить готовым пакетом записей, озвучкой ИИ в реальном времени со своим ключом или голосом телефона. Выбор сразу действует в финале.'),
            style: theme.textTheme.bodySmall,
          ),
          // Модуль выключаем не только в «Модулях»: сюда можно зайти прямо
          // из финалов, переключатель должен быть под рукой.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Модуль включён')),
            subtitle: Text(tr('Плитка «Озвучка» на главном экране')),
            value: moduleOn,
            onChanged: (v) => setState(() => ModulesSettings.set(db, AppModule.voice, v)),
          ),
          const SizedBox(height: 8),
          _EngineSelector(db: db),
          const SizedBox(height: 16),
          Text(tr('Пакеты озвучки'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            tr('Пакет — диктор, записанный заранее: не нужна сеть и ключ ИИ. Записи сделаны с частотой 16 кГц — весят примерно втрое меньше обычного, на слух это не мешает.'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // Язык интерфейса без пакета: диктор уйдёт по цепочке ИИ/TTS сам.
          if (VoicePackStore.entryFor(I18n.code) == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                tr('Для языка интерфейса готового пакета нет — финал озвучит ИИ своим ключом или голос телефона.'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ValueListenableBuilder<Map<String, VoicePackState>>(
            valueListenable: VoicePackStore.status,
            builder: (_, statuses, __) => ValueListenableBuilder<Map<String, ({int received, int total})>>(
              valueListenable: VoicePackStore.progress,
              builder: (_, progress, ___) => VoicePackStore.catalogLoaded
                  ? Column(
                      children: [
                        for (final e in VoicePackStore.catalog)
                          _PackCard(
                            db: db,
                            entry: e,
                            state: statuses[e.lang] ?? VoicePackState.notDownloaded,
                            progress: progress[e.lang],
                            verifyMessage: _verifyLang == e.lang ? _verifyMessage : null,
                            onDownload: () => _download(e.lang),
                            onDelete: () => _delete(e.lang),
                            onVerify: () => _verify(e.lang),
                          ),
                      ],
                    )
                  : Text(tr('Каталог пакетов недоступен'), style: theme.textTheme.bodySmall),
            ),
          ),
        ],
      ),
    );
  }
}

/// Выбор движка озвучки: сегмент из трёх вариантов (владелец 24.11):
/// «Пакет» / «ИИ в реальном времени (свой ключ)» / «Машинная (TTS телефона)».
class _EngineSelector extends StatelessWidget {
  final LocalDbService db;
  const _EngineSelector({required this.db});

  @override
  Widget build(BuildContext context) {
    final engine = VoicePackStore.engineOf(db);
    final available = VoicePacks.config(db).usable;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SegmentedButton<String>(
        selected: {engine},
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: VoicePackStore.enginePackage, label: Text(tr('Пакет'))),
          ButtonSegment(value: VoicePackStore.engineAi, label: Text(tr('ИИ (свой ключ)'))),
          ButtonSegment(value: VoicePackStore.engineTts, label: Text(tr('TTS телефона'))),
        ],
        onSelectionChanged: (s) => VoicePackStore.setEngine(db, s.first),
      ),
      const SizedBox(height: 6),
      Text(
        switch (engine) {
          VoicePackStore.enginePackage => tr('Финал сначала говорит готовым пакетом языка, чего нет — ИИ своим ключом, затем голос телефона.'),
          VoicePackStore.engineAi => available
              ? tr('Озвучка ИИ в реальном времени вашим ключом: записи готовятся заранее и кэшируются, нет записи — голос телефона.')
              : tr('Нужен свой ключ ИИ (настройки ИИ → «Свой ключ»): без него диктор говорит голосом телефона.'),
          _ => tr('Машинная озвучка средствами телефона: без сети, ключей и подготовленных записей.'),
        },
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}

/// Строка каталога: язык, размер, статус и кнопки «Скачать / Удалить / Проверить».
class _PackCard extends StatelessWidget {
  final LocalDbService db;
  final VoiceCatalogEntry entry;
  final VoicePackState state;
  final ({int received, int total})? progress;
  final String? verifyMessage;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onVerify;

  const _PackCard({
    required this.db,
    required this.entry,
    required this.state,
    required this.progress,
    required this.verifyMessage,
    required this.onDownload,
    required this.onDelete,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloading = progress != null;
    final statusText = switch (state) {
      VoicePackState.downloaded => tr('скачан'),
      VoicePackState.notDownloaded => tr('не скачан'),
      VoicePackState.unavailable => tr('недоступен'),
    };
    final sizeText = entry.bytes <= 0
        ? ''
        : ' · ${(entry.bytes / 1048576).toStringAsFixed(1)} МБ';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.record_voice_over_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${VoicePackStore.languageName(entry.lang)}  ·  ${tr('{n} записей', {'n': entry.phrases})}$sizeText  ·  $statusText',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ]),
          if (downloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress!.total > 0 ? progress!.received / progress!.total : null,
            ),
          ] else ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: state == VoicePackState.downloaded || state == VoicePackState.unavailable
                    ? null
                    : onDownload,
                icon: const Icon(Icons.download_outlined),
                label: Text(tr('Скачать')),
              ),
              OutlinedButton.icon(
                onPressed: state == VoicePackState.downloaded ? onDelete : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Удалить')),
              ),
              OutlinedButton.icon(
                onPressed: state == VoicePackState.downloaded ? onVerify : null,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(tr('Проверить')),
              ),
            ]),
          ],
          if (verifyMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(verifyMessage!, style: theme.textTheme.bodySmall),
            ),
        ]),
      ),
    );
  }
}
