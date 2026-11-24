import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'step_viewer_common.dart';

/// Синтетический https-origin: `androidx.webkit.WebViewAssetLoader` отдаёт
/// файлы из APK под ним. Только так работают ES-модули, importmap и
/// загрузка wasm — на `file:///android_asset/…` браузер это запрещает.
const _viewerBase =
    'https://appassets.androidplatform.net/assets/flutter_assets/assets/webview/';

/// Прячет ссылки в тексте ошибки: адрес модели может быть приватным
/// (подписанная ссылка Google Диска), а ошибка видна пользователю.
String _redactLinks(String text) =>
    text.replaceAll(RegExp(r'https?://\S+'), '<ссылка скрыта>');

/// Встроенный показ возможен только там, где есть WebView и AssetLoader.
bool get _canEmbed => defaultTargetPlatform == TargetPlatform.android;

/// Сборка вьюера. Вьюер открывается в ПОЛНОМ режиме — со своей шапкой
/// (замечания владельца 24.11, п.1: вернули собственную шапку, панели не
/// перекрываются). [onJs] вызывается, когда страница вьюера догрузилась и
/// отдала публичный API `window.NexusViewer`; для платформ без моста
/// (здесь это всё, кроме Android) он не вызывается никогда.
/// [onOpenCatalog] — кнопка «Каталог» в шапке самого вьюера: она зовёт
/// JS-хендлер `NexusApp` (метод openCatalog), зарегистрированный ниже.
Widget buildViewer(
  BuildContext context, {
  String? modelUrl,
  void Function(StepViewerJs? js)? onJs,
  VoidCallback? onOpenCatalog,
}) {
  if (!_canEmbed) return stepViewerFallback(context);
  return _Viewer(modelUrl: modelUrl, onJs: onJs, onOpenCatalog: onOpenCatalog);
}

/// Вьюер внутри APK: открывает файлы с телефона (кнопка «Открыть STEP»
/// в собственной шапке вьюера) и модели по ссылке (`?url=…`, страница
/// скачивает и разбирает локально).
class _Viewer extends StatefulWidget {
  final String? modelUrl;

  final void Function(StepViewerJs? js)? onJs;

  /// Тап по «Каталог» в шапке вьюера → открыть окошко каталога в Flutter
  /// (владелец 24.11: каталог как окошко, не отдельная страница).
  final VoidCallback? onOpenCatalog;

  const _Viewer({this.modelUrl, this.onJs, this.onOpenCatalog});

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  double _progress = 0;
  String? _error;
  InAppWebViewController? _controller;

  /// Догрузилась ли страница: до этого `evaluateJavascript` бессмыслен —
  /// `window.NexusViewer` ещё может не существовать.
  bool _pageReady = false;

  Uri get _initialUrl {
    final base = Uri.parse('${_viewerBase}index.html');
    return base.replace(queryParameters: {
      // Шапку вьюера НЕ прячем (возврат «как было ранее», замечание 1
      // владельца 24.11) — параметр embed больше не отправляем.
      if (widget.modelUrl != null && widget.modelUrl!.isNotEmpty)
        'url': widget.modelUrl!,
    });
  }

  /// Мост к `window.NexusViewer`. Небезопасные аргументы кодируем через
  /// `jsonEncode` (строки с кавычками/слэшами не ломают вызов). Возвращаем
  /// `null` и при отсутствии контроллера, и при отсутствии `window.NexusViewer`
  /// — внешне это одно и то же: «вьюер ещё не готов, пересоздай с ?url=».
  Future<Object?> _invoke(String method, List<Object?> args) async {
    final controller = _controller;
    if (!_pageReady || controller == null) return null;
    final jsArgs = [for (final a in args) jsonEncode(a)].join(',');
    try {
      final res = await controller.evaluateJavascript(
        source: 'window.NexusViewer'
            ' ? (window.NexusViewer.$method($jsArgs) ?? true)'
            ' : null',
      );
      return res;
    } catch (_) {
      // Страница в середине перезагрузки: мост временно недоступен.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_initialUrl.toString())),
          initialSettings: InAppWebViewSettings(
            // Отдаёт /assets/flutter_assets/** из APK под https-origin.
            webViewAssetLoader: WebViewAssetLoader(
              pathHandlers: [AssetsPathHandler(path: '/assets/')],
            ),
            javaScriptEnabled: true,
            domStorageEnabled: true,
            useShouldInterceptRequest: false,
            isInspectable: kDebugMode,
            allowFileAccess: false,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            allowContentAccess: false,
            transparentBackground: false,
          ),
          onWebViewCreated: (controller) {
            // JS-хендлер «NexusApp» (замечания владельца 24.11, п.C):
            // кнопка «Каталог» — первая слева в шапке самого вьюера —
            // зовёт window.NexusApp.openCatalog() или
            // window.flutter_inappwebview.callHandler('NexusApp',
            // 'openCatalog'). Здесь открываем окошко каталога. Хендлер
            // регистрируем сразу при создании WebView, чтобы кнопка
            // работала даже до onLoadStop.
            controller.addJavaScriptHandler(
              handlerName: 'NexusApp',
              callback: (args) {
                if (args.isEmpty || args.first == 'openCatalog') {
                  widget.onOpenCatalog?.call();
                }
                // Возвращаем null: ответ JS не ожидает (fire-and-forget).
                return null;
              },
            );
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress / 100);
          },
          onReceivedError: (controller, request, error) {
            if (mounted) setState(() => _error = _redactLinks(error.description));
          },
          onLoadStop: (controller, url) {
            _controller = controller;
            _pageReady = true;
            // Отдаём мост экрану: с этого момента доступны
            // `NexusViewer.load/edges/mass/display/openFile`.
            widget.onJs?.call(StepViewerJs(
              hasJs: true,
              ready: true,
              invoke: _invoke,
            ));
          },
          onConsoleMessage: (controller, message) {
            if (kDebugMode) {
              debugPrint('[viewer] ${message.messageLevel}: ${message.message}');
            }
          },
        ),
        if (_progress < 1)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: const Color(0xFF4C8DFF),
            ),
          ),
        if (_error != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Material(
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Вьюер не открылся: $_error',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
