import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_loader.dart';
import '../widgets/glass_pill.dart';

/// Одна запись общей памяти (таблица `notes` личной базы). Эмбеддинги и поисковые
/// векторы приложению не нужны и не загружаются.
class KnowledgeNote {
  final String id;
  final String topic;
  final String? summary;
  final String? category;
  final String? source;
  final List<String> tags;
  final DateTime? updatedAt;
  const KnowledgeNote({required this.id, required this.topic, this.summary, this.category, this.source, this.tags = const [], this.updatedAt});

  factory KnowledgeNote.fromJson(Map<String, dynamic> j) => KnowledgeNote(
        id: '${j['id']}',
        topic: '${j['topic'] ?? ''}',
        summary: j['summary'] as String?,
        category: j['category'] as String?,
        source: j['source'] as String?,
        tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
        updatedAt: DateTime.tryParse('${j['updated_at']}')?.toLocal(),
      );
}

/// Чтение общей памяти `notes`: страницы, поиск по теме/краткому описанию, фильтры по
/// источнику и метке. Только чтение — таблица общая с другим ИИ, чужие записи не меняем.
class KnowledgeNotesApi {
  KnowledgeNotesApi(this.auth, {http.Client Function()? clientFactory}) : _client = clientFactory ?? http.Client.new;
  final SupabaseAuthService auth;
  final http.Client Function() _client;

  static const pageSize = 40;
  static const _cols = 'id,topic,summary,category,source,tags,updated_at';

  /// Запрос списка: только активные записи, свежие сверху. [q] — подстрока в теме или
  /// кратком описании; [source] — точный источник; [tag] — запись содержит метку.
  static String listQuery({String q = '', String? source, String? tag, int offset = 0}) {
    final parts = <String>[
      'select=$_cols',
      'status=eq.active',
      'order=updated_at.desc',
      'limit=$pageSize',
      'offset=$offset',
    ];
    final text = q.trim().replaceAll(RegExp(r'[*,()]'), ' ').trim();
    if (text.isNotEmpty) {
      final e = Uri.encodeQueryComponent('*$text*');
      parts.add('or=(topic.ilike.$e,summary.ilike.$e)');
    }
    if (source != null) parts.add('source=eq.${Uri.encodeQueryComponent(source)}');
    if (tag != null) parts.add('tags=cs.${Uri.encodeQueryComponent('{"$tag"}')}');
    return parts.join('&');
  }

  Future<List<KnowledgeNote>> list({String q = '', String? source, String? tag, int offset = 0}) async {
    final rows = await _get(listQuery(q: q, source: source, tag: tag, offset: offset));
    return [for (final r in rows) KnowledgeNote.fromJson(r)];
  }

  Future<String> content(String id) async {
    final rows = await _get('select=content&id=eq.${Uri.encodeQueryComponent(id)}');
    return rows.isEmpty ? '' : '${rows.first['content'] ?? ''}';
  }

  /// Источники и их число (для фильтра): по первым записям, без отдельной функции на сервере.
  Future<Map<String, int>> sources() async {
    final rows = await _get('select=source&status=eq.active&limit=1000');
    final m = <String, int>{};
    for (final r in rows) {
      final s = '${r['source'] ?? ''}';
      if (s.isNotEmpty) m[s] = (m[s] ?? 0) + 1;
    }
    return m;
  }

  Future<List<Map<String, dynamic>>> _get(String query) async {
    final token = auth.isSignedIn ? await auth.ensureFreshToken() : null;
    final client = _client();
    try {
      final res = await client.get(
        Uri.parse('${auth.url}/rest/v1/notes?$query'),
        headers: {'apikey': auth.anonKey, 'Authorization': 'Bearer ${token ?? auth.anonKey}'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw Exception('notes: ${res.statusCode}');
      return (jsonDecode(utf8.decode(res.bodyBytes)) as List).cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }
}

/// «Вся память»: заметки приложения и вся база знаний из таблицы `notes` — со
/// списком, поиском, фильтрами и просмотром целиком.
class KnowledgeNotesScreen extends StatefulWidget {
  const KnowledgeNotesScreen({super.key});

  @override
  State<KnowledgeNotesScreen> createState() => _KnowledgeNotesScreenState();
}

class _KnowledgeNotesScreenState extends State<KnowledgeNotesScreen> {
  late final KnowledgeNotesApi _api = KnowledgeNotesApi(SupabaseAuthService(context.read<AppDataStore>().db));
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<KnowledgeNote> _items = [];
  Map<String, int> _sources = {};
  String? _source;
  String? _tag;
  bool _loading = true;
  bool _more = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_more && !_loading && _scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _load(more: true);
    });
    _load();
    _api.sources().then((s) {
      if (mounted) setState(() => _sources = s);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.list(q: _search.text, source: _source, tag: _tag, offset: more ? _items.length : 0);
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...page] : page;
        _more = page.length >= KnowledgeNotesApi.pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(KnowledgeNote n) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _NoteDetail(api: _api, note: n)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('Вся память'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: tr('Поиск по теме и описанию'),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        _load();
                      },
                    ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _load(),
          ),
          if (_sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(tr('Все')),
                    selected: _source == null,
                    onSelected: (_) {
                      _source = null;
                      _load();
                    },
                  ),
                ),
                for (final e in _sources.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${e.key} · ${e.value}'),
                      selected: _source == e.key,
                      onSelected: (_) {
                        _source = e.key;
                        _load();
                      },
                    ),
                  ),
              ]),
            ),
          ],
          if (_tag != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  label: Text('# $_tag'),
                  onDeleted: () {
                    _tag = null;
                    _load();
                  },
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
          if (_items.isEmpty && !_loading && _error == null) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(tr('Ничего не найдено')))),
          for (final n in _items)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open(n),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n.topic, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    if ((n.summary ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(n.summary!, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    ],
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if ((n.source ?? '').isNotEmpty) _pill(theme, n.source!, cs.secondaryContainer),
                      if ((n.category ?? '').isNotEmpty) _pill(theme, n.category!, cs.surfaceContainerHighest),
                      for (final t in n.tags.take(4))
                        GestureDetector(
                          onTap: () {
                            _tag = t;
                            _load();
                          },
                          child: Text('#$t', style: theme.textTheme.labelSmall?.copyWith(color: cs.primary)),
                        ),
                    ]),
                  ]),
                ),
              ),
            ),
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: SizedBox(height: 60, child: AppLoader())),
        ],
      ),
    );
  }

  Widget _pill(ThemeData theme, String text, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: theme.textTheme.labelSmall),
      );
}

class _NoteDetail extends StatefulWidget {
  final KnowledgeNotesApi api;
  final KnowledgeNote note;
  const _NoteDetail({required this.api, required this.note});

  @override
  State<_NoteDetail> createState() => _NoteDetailState();
}

class _NoteDetailState extends State<_NoteDetail> {
  String? _content;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.content(widget.note.id).then((c) {
      if (mounted) setState(() => _content = c);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = friendlyError(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.note;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(n.topic, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 8, 16, 24),
        children: [
          Wrap(spacing: 8, runSpacing: 4, children: [
            if ((n.source ?? '').isNotEmpty) Chip(label: Text(n.source!), visualDensity: VisualDensity.compact),
            if ((n.category ?? '').isNotEmpty) Chip(label: Text(n.category!), visualDensity: VisualDensity.compact),
            for (final t in n.tags) Chip(label: Text('#$t'), visualDensity: VisualDensity.compact),
          ]),
          if ((n.summary ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(n.summary!, style: theme.textTheme.titleSmall),
          ],
          const SizedBox(height: 12),
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error))
          else if (_content == null)
            const SizedBox(height: 80, child: AppLoader())
          else
            SelectableText(_content!.isEmpty ? tr('Текста нет') : _content!, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
