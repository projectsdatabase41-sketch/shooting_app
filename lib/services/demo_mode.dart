import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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
    if (name == '/') name = null; // стартовый маршрут безымянный
    if (route is ModalRoute) {
      final ctx = route.subtreeContext;
      if (ctx != null) name ??= _findScreenName(ctx);
    }
    name ??= route?.runtimeType.toString() ?? 'unknown';
    final t = tab;
    return t == null || !name.contains('HomeShell') ? name : '$name / $t';
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

  static DateTime? _lastSent;

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
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/rest/v1/app_feedback'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer ${ChatSettings.anonKey}',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode({
              'text': t.length > 4000 ? t.substring(0, 4000) : t,
              'page': page.length > 200 ? page.substring(0, 200) : page,
              'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            }),
          )
          .timeout(const Duration(seconds: 15));
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
  Offset? _pos; // от правого нижнего угла

  Future<void> _open() async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    final page = DemoMode.currentPage();
    final ctl = TextEditingController();
    await showDialog<void>(
      context: ctx,
      builder: (dctx) {
        var busy = false;
        String? error;
        return StatefulBuilder(
          builder: (dctx, setS) => AlertDialog(
            title: Text(tr('Отзыв о приложении')),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Страница: {p}', {'p': page}), style: Theme.of(dctx).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(tr('Отправляется только текст и название страницы, без личных данных.'),
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
                        final err = await DemoMode.send(ctl.text, page);
                        if (!dctx.mounted) return;
                        if (err == null) {
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
    ctl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: widget.child),
      ValueListenableBuilder<bool>(
        valueListenable: DemoMode.enabled,
        builder: (context, on, _) {
          if (!on) return const SizedBox.shrink();
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
                  _pos = Offset((p.dx - d.delta.dx).clamp(0, size.width - 90), (p.dy - d.delta.dy).clamp(0, size.height - 80));
                }),
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: _open,
                  icon: const Icon(Icons.rate_review_outlined),
                  label: Text(tr('Отзыв')),
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
