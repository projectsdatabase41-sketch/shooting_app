import '../widgets/glass_route.dart';
import 'dart:convert';

import '../widgets/glass_pill.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/home_tab_specs.dart';
import '../voice/voice_control.dart';
import '../voice/voice_overlay.dart';
import '../widgets/fan_menu.dart';
import 'screen_buttons.dart';
import 'app_update_service.dart';
import '../i18n/i18n.dart';
import 'chat_settings.dart';
import 'local_db_service.dart';

/// Режим «Демо»: на каждой странице кнопка «Отзыв». Текст и название страницы
/// уходят в отдельную таблицу публичной базы (sql/app-feedback.sql) — без
/// персональных данных, без чтения из приложения и из ИИ.
class DemoMode {
  DemoMode._();

  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static const _key = 'demo_mode';

  /// Текущая вкладка главного экрана (ставит HomeShell).
  static String? tab;

  static void load(LocalDbService db) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_key]);
    enabled.value = rows.isNotEmpty && '${rows.first['hex']}' == '1';
  }

  static void set(LocalDbService db, bool v) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [_key, v ? '1' : '0'],
    );
    enabled.value = v;
  }

  /// Название страницы для отзыва: экран верхнего маршрута (+ вкладка).
  static String currentPage() {
    final route = DemoRouteObserver.instance.top;
    String? name = route?.settings.name;
    String? title;
    if (name == '/') name = null; // стартовый маршрут безымянный
    if (route is ModalRoute) {
      final ctx = route.subtreeContext;
      if (ctx != null) {
        title = _findTitle(ctx);
        name ??= _findScreenName(ctx);
      }
    }
    name ??= route?.runtimeType.toString() ?? 'unknown';
    // В веб-сборке имена классов сжаты — читаемым остаётся заголовок экрана.
    if (title != null && title.isNotEmpty) name = name.startsWith('minified:') ? title : '$title ($name)';
    final t = tab;
    return t == null || !name.contains('HomeShell') ? name : '$name / $t';
  }

  /// Данные с экрана текстом (вместо скриншота): видимые надписи, состояние переключателей и
  /// флажков. Поля ввода не читаются (там может быть личное). Не больше [maxChars] знаков.
  static String screenSnapshot({int maxChars = 2500}) {
    final route = DemoRouteObserver.instance.top;
    final ctx = route is ModalRoute ? route.subtreeContext : null;
    if (ctx == null) return '';
    final lines = <String>[];
    String? prev;
    var visited = 0;
    var size = 0;
    void add(String s) {
      final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty || t == prev || size > maxChars) return;
      prev = t;
      size += t.length + 1;
      lines.add(t);
    }

    void walk(Element e) {
      if (visited++ > 6000 || size > maxChars) return;
      final w = e.widget;
      if (w is Offstage && w.offstage) return;
      if (w is Opacity && w.opacity == 0) return;
      if (w is EditableText) return; // поля ввода не читаем
      if (w is Text) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.size.isEmpty) return;
        add(w.data ?? w.textSpan?.toPlainText() ?? '');
      } else if (w is Switch) {
        add('[переключатель: ${w.value ? 'вкл' : 'выкл'}]');
      } else if (w is Checkbox) {
        add('[флажок: ${w.value == true ? 'да' : 'нет'}]');
      } else if (w is Slider) {
        add('[ползунок: ${w.value.toStringAsFixed(2)}]');
      }
      e.visitChildren(walk);
    }

    (ctx as Element).visitChildren(walk);
    return lines.join('\n');
  }

  /// Текст заголовка экрана (AppBar / GlassHeader): первый Text внутри шапки.
  static String? _findTitle(BuildContext ctx) {
    String? result;
    var visited = 0;
    void inHeader(Element e) {
      if (result != null || visited++ > 300) return;
      final w = e.widget;
      if (w is Text && (w.data ?? '').trim().isNotEmpty) {
        result = w.data!.trim();
        return;
      }
      e.visitChildren(inHeader);
    }

    void walk(Element e) {
      if (result != null || visited++ > 1500) return;
      final n = e.widget.runtimeType.toString();
      if (e.widget is AppBar || n.contains('GlassHeader')) {
        e.visitChildren(inHeader);
        return;
      }
      e.visitChildren(walk);
    }

    (ctx as Element).visitChildren(walk);
    return result;
  }

  static String? _findScreenName(BuildContext ctx) {
    String? found;
    var visited = 0;
    bool looksLikeScreen(String n) =>
        n.endsWith('Screen') || n.endsWith('Page') || n.endsWith('Shell') || n.endsWith('Gate');
    void walk(Element e) {
      if (found != null || visited++ > 400) return;
      final n = e.widget.runtimeType.toString();
      if (looksLikeScreen(n) && !n.startsWith('_Material')) {
        found = n;
        return;
      }
      e.visitChildren(walk);
    }

    (ctx as Element).visitChildren(walk);
    return found;
  }

  /// Версия сборки: короткий SHA коммита (APK) или время сборки (веб); локально — «dev».
  static String get appVersion {
    final sha = AppUpdateService.currentSha;
    if (sha.length >= 7) return sha.substring(0, 7);
    final t = AppUpdateService.buildTime;
    return t.isEmpty ? 'dev' : t;
  }

  /// Отправка в app_feedback с версией приложения. Колонки app_version может ещё не
  /// быть в базе (sql/app-feedback-version.sql) — тогда повторяем без неё.
  static Future<http.Response> _post(http.Client client, Map<String, dynamic> body) async {
    Future<http.Response> go(Map<String, dynamic> b) => client.post(
          Uri.parse('${ChatSettings.url}/rest/v1/app_feedback'),
          headers: {
            'apikey': ChatSettings.anonKey,
            'Authorization': 'Bearer ${ChatSettings.anonKey}',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
          },
          body: jsonEncode(b),
        ).timeout(const Duration(seconds: 15));
    // Колонки app_version и demo могут быть ещё не созданы в базе (sql/app-feedback-version.sql,
    // sql/app-feedback-demo.sql) — тогда повторяем без них.
    var res = await go({...body, 'app_version': appVersion, 'demo': enabled.value});
    if (res.statusCode == 400) res = await go({...body, 'app_version': appVersion});
    if (res.statusCode == 400) res = await go(body);
    return res;
  }

  static DateTime? _lastSent;
  static DateTime? _lastError;
  static final Set<String> _sentErrors = {};

  /// Отчёт об ошибке в ту же таблицу отзывов: что случилось, где, технические
  /// подробности (тип ошибки, стек, платформа) — без личных данных.
  static Future<String?> sendError(String where, Object error, [StackTrace? stack, String? extra]) async {
    if (!ChatSettings.isConfigured) return tr('Сервер отзывов не настроен');
    // Одну и ту же ошибку за сеанс шлём один раз; разные — не чаще раза в 2 с.
    final key = '$where|${'$error'.length > 160 ? '$error'.substring(0, 160) : '$error'}';
    if (!_sentErrors.add(key)) return null;
    final last = _lastError;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 2)) return null;
    _lastError = DateTime.now();
    final st = (stack?.toString() ?? '').split('\n').take(12).join('\n');
    var screen = '';
    try {
      screen = screenSnapshot(maxChars: 1000);
    } catch (_) {}
    final text = '[ОШИБКА] $error\nТип: ${error.runtimeType}\nГде: $where'
        '${extra == null ? '' : '\n$extra'}${st.isEmpty ? '' : '\n--- стек ---\n$st'}${screen.isEmpty ? '' : '\n--- экран ---\n$screen'}';
    final client = http.Client();
    try {
      final res = await _post(client, {
        'text': text.length > 4000 ? text.substring(0, 4000) : text,
        'page': 'ERROR: ${where.length > 190 ? where.substring(0, 190) : where}',
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
      return res.statusCode >= 300 ? tr('Не удалось отправить (код {c})', {'c': res.statusCode}) : null;
    } catch (_) {
      return tr('Нет сети');
    } finally {
      client.close();
    }
  }

  /// Показывает сообщение об ошибке и сразу сам отправляет подробности
  /// разработчику (без участия человека).
  static void reportError(BuildContext context, String message, String where, Object error, [StackTrace? stack]) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Отчёт уходит сам всегда (так разработчик видит сбои у всех); в режиме
    // разработчика человек видит это и в сообщении.
    sendError(where, error, stack);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Отправка отзыва. Возвращает текст ошибки или `null`.
  static Future<String?> send(String text, String page) async {
    final t = text.trim();
    if (t.isEmpty) return tr('Напишите текст отзыва');
    if (!ChatSettings.isConfigured) return tr('Сервер отзывов не настроен');
    final last = _lastSent;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 10)) {
      return tr('Подождите несколько секунд перед следующим отзывом');
    }
    final client = http.Client();
    try {
      final res = await _post(client, {
        'text': t.length > 4000 ? t.substring(0, 4000) : t,
        'page': page.length > 200 ? page.substring(0, 200) : page,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
      if (res.statusCode >= 300) return tr('Не удалось отправить (код {c})', {'c': res.statusCode});
      _lastSent = DateTime.now();
      return null;
    } catch (_) {
      return tr('Нет сети');
    } finally {
      client.close();
    }
  }
}

/// Следит за стеком маршрутов, чтобы знать, какая страница сейчас сверху.
class DemoRouteObserver extends NavigatorObserver {
  DemoRouteObserver._();
  static final instance = DemoRouteObserver._();

  final List<Route<dynamic>> _stack = [];

  /// Верхняя страница (не диалог и не нижнее окно).
  Route<dynamic>? get top {
    for (var i = _stack.length - 1; i >= 0; i--) {
      if (_stack[i] is PageRoute) return _stack[i];
    }
    return _stack.isEmpty ? null : _stack.last;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (i >= 0) {
      if (newRoute != null) {
        _stack[i] = newRoute;
      } else {
        _stack.removeAt(i);
      }
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
  }
}

/// Плавающая кнопка «Отзыв» поверх всего приложения (её можно перетащить).
class DemoFeedbackOverlay extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  const DemoFeedbackOverlay({super.key, required this.navigatorKey, required this.child});

  @override
  State<DemoFeedbackOverlay> createState() => _DemoFeedbackOverlayState();
}

class _DemoFeedbackOverlayState extends State<DemoFeedbackOverlay> {
  /// Недописанный отзыв сохраняется, если окно закрыли (чтобы не терять текст).
  static String _draft = '';

  Offset? _pos; // от правого нижнего угла

  Future<void> _open() async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    final page = DemoMode.currentPage();
    var screen = '';
    try {
      screen = DemoMode.screenSnapshot();
    } catch (_) {}
    var attach = screen.isNotEmpty;
    final ctl = TextEditingController(text: _draft);
    await showGlassDialog<void>(
      context: ctx,
      builder: (dctx) {
        var busy = false;
        String? error;
        return StatefulBuilder(
          builder: (dctx, setS) => AlertDialog(
            title: Text(tr('Отзыв о приложении')),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Отправляется анонимно: только текст, платформа и версия приложения, без личных данных.'),
                    style: Theme.of(dctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: ctl,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 4000,
                  decoration: InputDecoration(hintText: tr('Что не так или что улучшить?')),
                ),
                if (screen.isNotEmpty)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: attach,
                    onChanged: (v) => setS(() => attach = v ?? false),
                    title: Text(tr('Приложить данные экрана (текстом, без полей ввода)'), style: Theme.of(dctx).textTheme.bodySmall),
                  ),
                if (error != null) Text(error!, style: TextStyle(color: Theme.of(dctx).colorScheme.error)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dctx), child: Text(tr('Закрыть'))),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setS(() => busy = true);
                        final body = attach ? '${ctl.text.trim()}\n\n--- экран ---\n$screen' : ctl.text;
                        final err = await DemoMode.send(body, page);
                        if (!dctx.mounted) return;
                        if (err == null) {
                          ctl.clear();
                          Navigator.pop(dctx);
                          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(tr('Спасибо за отзыв!'))));
                        } else {
                          setS(() {
                            busy = false;
                            error = err;
                          });
                        }
                      },
                child: Text(tr('Отправить')),
              ),
            ],
          ),
        );
      },
    );
    _draft = ctl.text;
    ctl.dispose();
  }

  @override
  void initState() {
    super.initState();
    ScreenButtons.openFeedback = _open;
  }

  @override
  void dispose() {
    if (ScreenButtons.openFeedback == _open) ScreenButtons.openFeedback = null;
    super.dispose();
  }

  /// Единая кнопка «Кнопки на экране»: одна — работает сразу, несколько — раскрываются веером.
  Widget _screenButtons() {
    return ValueListenableBuilder<bool>(
      valueListenable: ScreenButtons.on,
      builder: (context, master, _) {
        if (!master) return const SizedBox.shrink();
        return AnimatedBuilder(
          animation: Listenable.merge([
            DemoMode.enabled,
            VoiceSettings.enabled,
            ScreenButtons.tabs,
            VoiceControl.instance.listening,
          ]),
          builder: (context, _) {
            final listening = VoiceControl.instance.listening.value;
            final items = <FanItem>[
              if (DemoMode.enabled.value)
                FanItem(
                    child: const Icon(Icons.rate_review_outlined), label: tr('Отзыв'), onSelect: _open),
              if (VoiceSettings.enabled.value)
                FanItem(
                  child: Icon(listening ? Icons.mic : Icons.mic_none),
                  label: tr('Голосовое управление'),
                  active: listening,
                  onSelect: () => ScreenButtons.voiceTap?.call(),
                ),
              for (final id in ScreenButtons.visibleTabs)
                FanItem(
                  child: Icon(homeTabSpecs[id]!.icon),
                  label: tr(homeTabSpecs[id]!.label),
                  onSelect: () => ScreenButtons.openTab?.call(id),
                ),
            ];
            if (items.isEmpty) return const SizedBox.shrink();
            final single = items.length == 1;
            return Positioned(
              right: 8,
              bottom: 120,
              child: Material(
                color: Colors.transparent,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (listening)
                    ValueListenableBuilder<String>(
                      valueListenable: VoiceControl.instance.heard,
                      builder: (_, t, __) => Container(
                        constraints: const BoxConstraints(maxWidth: 240),
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                        child: Text(t.isEmpty ? tr('Говорите…') : t, style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  if (single)
                    GlassCircleButton(
                      icon: BoldIcon((items.first.child as Icon).icon!),
                      color: listening ? Colors.redAccent.withValues(alpha: 0.55) : null,
                      onTap: items.first.onSelect,
                    )
                  else
                    FanButton(
                      navigatorKey: widget.navigatorKey,
                      icon: const GlassCircleButton(icon: BoldIcon(Icons.apps)),
                      items: items,
                    ),
                ]),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: VoiceOverlay(navigatorKey: widget.navigatorKey, child: widget.child)),
      _screenButtons(),
      AnimatedBuilder(
        animation: Listenable.merge([DemoMode.enabled, ScreenButtons.on]),
        builder: (context, _) {
          // Кнопка отзыва видна при включённом «Режиме Демо» (режим разработчика не нужен).
          // При включённых «Кнопках на экране» она живёт в общем веере.
          if (!DemoMode.enabled.value || ScreenButtons.on.value) return const SizedBox.shrink();
          final size = MediaQuery.sizeOf(context);
          final pos = _pos ?? const Offset(8, 120);
          return Positioned(
            right: pos.dx,
            bottom: pos.dy,
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  final p = _pos ?? const Offset(8, 120);
                  _pos = Offset((p.dx - d.delta.dx).clamp(0, size.width - 56), (p.dy - d.delta.dy).clamp(0, size.height - 56));
                }),
                // круглая, как кнопка «назад» (48 px); без tooltip — здесь нет Overlay
                child: GlassCircleButton(
                  icon: const BoldIcon(Icons.rate_review_outlined),
                  onTap: _open,
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
