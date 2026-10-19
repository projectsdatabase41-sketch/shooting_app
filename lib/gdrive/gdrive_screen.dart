import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import '../logic/save_to_app_folder.dart';
import '../state/app_data_store.dart';
import '../widgets/app_loader.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import 'gdrive_service.dart';

/// Модуль «Google Диск»: папки и файлы вашего Диска, поиск, просмотр, правка текста,
/// загрузка, переименование, удаление. Работает через мост Apps Script (docs/gdrive-script.gs).
class GDriveScreen extends StatefulWidget {
  const GDriveScreen({super.key});

  @override
  State<GDriveScreen> createState() => _GDriveScreenState();
}

class _GDriveScreenState extends State<GDriveScreen> {
  late final _db = context.read<AppDataStore>().db;
  late GDriveService _svc = GDriveService(_db);

  /// Путь от корня: (id папки, имя). Последний — текущая.
  final List<(String, String)> _path = [('root', 'Мой диск')];
  DriveListing? _listing;
  List<DriveItem>? _found;
  String? _error;
  bool _busy = false;
  bool _searching = false;
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (GDriveService.configured(_db)) _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  String get _cur => _path.last.$1;

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _found = null;
    });
    try {
      final l = await _svc.list(_cur);
      if (mounted) setState(() => _listing = l);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _found = null);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _svc.search(q.trim());
      if (mounted) setState(() => _found = r);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openFolder(DriveItem f) {
    _path.add((f.id, f.name));
    _searching = false;
    _searchCtl.clear();
    _load();
  }

  bool _up() {
    if (_searching) {
      setState(() {
        _searching = false;
        _found = null;
        _searchCtl.clear();
      });
      return true;
    }
    if (_path.length <= 1) return false;
    _path.removeLast();
    _load();
    return true;
  }

  Future<void> _run(Future<void> Function() job, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await job();
      if (ok != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<String?> _ask(String title, {String initial = ''}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(tr('ОК'))),
        ],
      ),
    );
  }

  Future<void> _newFolder() async {
    final name = (await _ask(tr('Новая папка')))?.trim();
    if (name == null || name.isEmpty) return;
    await _run(() => _svc.mkdir(_cur, name));
  }

  Future<void> _upload() async {
    final r = await FilePicker.platform.pickFiles(withData: true);
    final f = r?.files.firstOrNull;
    final bytes = f?.bytes;
    if (f == null || bytes == null) return;
    await _run(() async {
      await _svc.put(_cur, f.name, _mimeOf(f.name), bytes);
    }, ok: tr('Загружено: {n}', {'n': f.name}));
  }

  static String _mimeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'gif': 'image/gif',
          'webp': 'image/webp',
          'pdf': 'application/pdf',
          'txt': 'text/plain',
          'md': 'text/plain',
          'csv': 'text/csv',
          'json': 'application/json',
          'mp4': 'video/mp4',
          'mp3': 'audio/mpeg',
        }[ext] ??
        'application/octet-stream';
  }

  Future<void> _rename(DriveItem it) async {
    final name = (await _ask(tr('Новое имя'), initial: it.name))?.trim();
    if (name == null || name.isEmpty || name == it.name) return;
    await _run(() => _svc.rename(it.id, name));
  }

  Future<void> _delete(DriveItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить «{n}»?', {'n': it.name})),
        content: Text(tr('Уйдёт в корзину Google Диска, оттуда можно вернуть.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Удалить'))),
        ],
      ),
    );
    if (ok == true) await _run(() => _svc.trash(it.id));
  }

  Future<void> _open(DriveItem it) async {
    if (it.isFolder) return _openFolder(it);
    setState(() => _busy = true);
    try {
      if (!(it.isImage || it.isText)) {
        await launchUrl(Uri.parse(it.url), mode: LaunchMode.externalApplication);
        return;
      }
      final f = await _svc.get(it.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => it.isImage ? _ImageViewer(file: f) : _TextEditor(svc: _svc, item: it, file: f),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(DriveItem it) async {
    setState(() => _busy = true);
    try {
      final f = await _svc.get(it.id);
      final ok = await saveToAppFolder(f.bytes, f.name, f.mime);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ok ? tr('Сохранено в папку Nexus: {n}', {'n': f.name}) : tr('Не удалось сохранить файл'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _icon(DriveItem it) {
    if (it.isFolder) return Icons.folder_outlined;
    if (it.isImage) return Icons.image_outlined;
    if (it.mime.startsWith('video/')) return Icons.movie_outlined;
    if (it.mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (it.mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (it.isText) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _size(int b) => b < 1024
      ? '$b Б'
      : b < 1024 * 1024
          ? '${(b / 1024).toStringAsFixed(0)} КБ'
          : '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';

  Widget _row(DriveItem it) {
    final df = DateFormat('dd.MM.yy HH:mm');
    return ListTile(
      leading: Icon(_icon(it)),
      title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(it.isFolder ? df.format(it.modified) : '${_size(it.size)} · ${df.format(it.modified)}'),
      onTap: () => _open(it),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'web':
              launchUrl(Uri.parse(it.url), mode: LaunchMode.externalApplication);
            case 'dl':
              _download(it);
            case 'ren':
              _rename(it);
            case 'del':
              _delete(it);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'web', child: Text(tr('Открыть в Google Диске'))),
          if (!it.isFolder) PopupMenuItem(value: 'dl', child: Text(tr('Скачать на телефон'))),
          PopupMenuItem(value: 'ren', child: Text(tr('Переименовать'))),
          PopupMenuItem(value: 'del', child: Text(tr('Удалить'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top + GlassHeader.height;
    if (!GDriveService.configured(_db)) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(title: Text(tr('Google Диск'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        body: GDriveSetup(
          top: top,
          onConnected: () => setState(() {
            _svc = GDriveService(_db);
            _load();
          }),
        ),
      );
    }
    final items = _found ?? [...?_listing?.folders, ...?_listing?.files];
    return PopScope(
      canPop: _path.length <= 1 && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
          title: _searching
              ? TextField(
                  controller: _searchCtl,
                  autofocus: true,
                  decoration: InputDecoration(hintText: tr('Поиск по названию'), border: InputBorder.none),
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                )
              : Text(_path.last.$2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          actions: [
            GlassCircleButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              tooltip: tr('Поиск'),
              onTap: () => _searching ? _up() : setState(() => _searching = true),
            ),
            if (!_searching)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'refresh') _load();
                  if (v == 'off') {
                    GDriveService.disconnect(_db);
                    setState(() {
                      _listing = null;
                      _path
                        ..clear()
                        ..add(('root', 'Мой диск'));
                    });
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'refresh', child: Text(tr('Обновить'))),
                  PopupMenuItem(value: 'off', child: Text(tr('Отключить Google Диск'))),
                ],
              ),
          ],
        ),
        floatingActionButton: _searching
            ? null
            : Column(mainAxisSize: MainAxisSize.min, children: [
                FloatingActionButton.small(heroTag: 'gd-folder', onPressed: _busy ? null : _newFolder, child: const Icon(Icons.create_new_folder_outlined)),
                const SizedBox(height: 10),
                FloatingActionButton(heroTag: 'gd-up', onPressed: _busy ? null : _upload, child: const Icon(Icons.upload_file)),
              ]),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, top, 24, 0),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: Text(tr('Повторить'))),
                  ]),
                ),
              )
            : (_listing == null && _busy)
                ? const AppLoader()
                : RefreshIndicator(
                    edgeOffset: top,
                    onRefresh: _load,
                    child: items.isEmpty
                        ? ListView(padding: EdgeInsets.only(top: top), children: [
                            SizedBox(
                                height: 300,
                                child: EmptyState(
                                    icon: Icons.folder_open_outlined, text: _found != null ? tr('Ничего не найдено') : tr('Папка пуста'))),
                          ])
                        : ListView.builder(
                            padding: EdgeInsets.only(top: top, bottom: 140),
                            itemCount: items.length + (_busy ? 1 : 0),
                            itemBuilder: (_, i) => i == items.length
                                ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                                : _row(items[i]),
                          ),
                  ),
      ),
    );
  }
}

/// Подключение моста: инструкция, адрес и пароль.
class GDriveSetup extends StatefulWidget {
  final double top;
  final VoidCallback onConnected;
  const GDriveSetup({super.key, required this.top, required this.onConnected});

  @override
  State<GDriveSetup> createState() => _GDriveSetupState();
}

class _GDriveSetupState extends State<GDriveSetup> {
  late final _db = context.read<AppDataStore>().db;
  final _url = TextEditingController();
  final _secret = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _copyScript() async {
    final msg = ScaffoldMessenger.of(context);
    final text = await rootBundle.loadString('docs/gdrive-script.gs');
    await Clipboard.setData(ClipboardData(text: text));
    msg.showSnackBar(SnackBar(content: Text(tr('Скрипт скопирован — вставьте его в Google Apps Script'))));
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    GDriveService.save(_db, url: _url.text, secret: _secret.text);
    try {
      await GDriveService(_db).ping();
      if (mounted) widget.onConnected();
    } catch (e) {
      GDriveService.disconnect(_db);
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, widget.top + 8, 16, 32),
      children: [
        Text(tr('Подключите свой Google Диск'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(tr('Работает через небольшой скрипт в вашем аккаунте Google: Nexus видит только то, что вы ему разрешили, и ничего не отдаёт без вашего пароля.')),
        const SizedBox(height: 12),
        Text(tr('1. Нажмите «Скопировать скрипт».\n2. Откройте script.google.com → Новый проект, вставьте скрипт и впишите свой пароль в строке SECRET.\n3. Развернуть → Новое развёртывание → Веб-приложение: выполнять от имени «Я», доступ «Все». Разрешите доступ к Диску.\n4. Скопируйте адрес веб-приложения (заканчивается на /exec) сюда вместе с паролем.')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: _copyScript, icon: const Icon(Icons.copy_outlined), label: Text(tr('Скопировать скрипт'))),
        OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse('https://script.google.com'), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new),
            label: Text(tr('Открыть Apps Script'))),
        const SizedBox(height: 16),
        TextField(controller: _url, decoration: InputDecoration(labelText: tr('Адрес веб-приложения (…/exec)'))),
        const SizedBox(height: 8),
        TextField(controller: _secret, obscureText: true, decoration: InputDecoration(labelText: tr('Пароль (SECRET из скрипта)'))),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _connect, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(tr('Подключить'))),
      ],
    );
  }
}

class _ImageViewer extends StatelessWidget {
  final DriveFile file;
  const _ImageViewer({required this.file});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(file.name, overflow: TextOverflow.ellipsis), backgroundColor: Colors.black54, foregroundColor: Colors.white),
        body: Center(child: InteractiveViewer(maxScale: 6, child: Image.memory(file.bytes))),
      );
}

class _TextEditor extends StatefulWidget {
  final GDriveService svc;
  final DriveItem item;
  final DriveFile file;
  const _TextEditor({required this.svc, required this.item, required this.file});

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final _ctl = TextEditingController(text: utf8.decode(widget.file.bytes, allowMalformed: true));
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final msg = ScaffoldMessenger.of(context);
    try {
      await widget.svc.put('root', widget.item.name, widget.item.mime, Uint8List.fromList(utf8.encode(_ctl.text)), overwriteId: widget.item.id);
      msg.showSnackBar(SnackBar(content: Text(tr('Сохранено'))));
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.item.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: tr('Сохранить'),
              onPressed: _saving ? null : _save,
              icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(controller: _ctl, expands: true, maxLines: null, minLines: null, textAlignVertical: TextAlignVertical.top, style: const TextStyle(fontFamily: 'monospace')),
        ),
      );
}
