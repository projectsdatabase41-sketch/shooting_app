import 'package:flutter/material.dart';

import '../finals/voice_packs.dart';
import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import '../widgets/glass_pill.dart';

/// Записи диктора по одной: послушать, озвучить заново только одну (экономит трафик), удалить.
class FinalsVoiceClipsScreen extends StatefulWidget {
  final LocalDbService db;
  const FinalsVoiceClipsScreen({super.key, required this.db});

  @override
  State<FinalsVoiceClipsScreen> createState() => _FinalsVoiceClipsScreenState();
}

class _FinalsVoiceClipsScreenState extends State<FinalsVoiceClipsScreen> {
  final Set<String> _busy = {};
  final Map<String, bool> _exists = {};
  late final _groups = VoicePacks.groups(widget.db);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final g in _groups) {
      for (final (ref, _) in g.$2) {
        _exists[ref] = await VoicePacks.clipExists(widget.db, ref);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _regen(String ref, String text) async {
    setState(() => _busy.add(ref));
    final ok = await VoicePacks.regenerate(widget.db, ref, text);
    _exists[ref] = await VoicePacks.clipExists(widget.db, ref);
    if (!mounted) return;
    setState(() => _busy.remove(ref));
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Сервис озвучки не ответил'))));
  }

  /// Озвучить заново все записи группы (одно имя) или только недостающие.
  Future<void> _group(List<(String, String)> items, {required bool onlyMissing}) async {
    for (final (ref, text) in items) {
      if (onlyMissing && _exists[ref] == true) continue;
      await _regen(ref, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Записи по одной'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + GlassHeader.height, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(tr('Нажмите ↻, чтобы озвучить заново только эту запись; остальные не трогаются и трафик не тратится.'), style: theme.textTheme.bodySmall),
          ),
          for (final g in _groups)
            ExpansionTile(
              title: Text(g.$1),
              subtitle: Text(tr('Готово: {a} из {b}', {'a': g.$2.where((e) => _exists[e.$1] == true).length, 'b': g.$2.length})),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 8, children: [
                    TextButton(onPressed: () => _group(g.$2, onlyMissing: true), child: Text(tr('Озвучить недостающие'))),
                    TextButton(onPressed: () => _group(g.$2, onlyMissing: false), child: Text(tr('Озвучить заново все'))),
                  ]),
                ),
                for (final (ref, text) in g.$2)
                  ListTile(
                    dense: true,
                    leading: Icon(_exists[ref] == true ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: _exists[ref] == true ? Colors.green : theme.hintColor, size: 20),
                    title: Text(text),
                    trailing: _busy.contains(ref)
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              tooltip: tr('Послушать'),
                              icon: const Icon(Icons.play_arrow),
                              onPressed: _exists[ref] == true ? () => VoicePacks.play(widget.db, [ref], queue: false) : null,
                            ),
                            IconButton(tooltip: tr('Озвучить заново'), icon: const Icon(Icons.refresh), onPressed: () => _regen(ref, text)),
                            IconButton(
                              tooltip: tr('Удалить'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _exists[ref] == true
                                  ? () async {
                                      await VoicePacks.deleteClip(widget.db, ref);
                                      _exists[ref] = false;
                                      if (mounted) setState(() {});
                                    }
                                  : null,
                            ),
                          ]),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
