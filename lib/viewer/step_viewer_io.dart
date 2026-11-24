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

/// Сборка вьюера. [embed] — режим встраивания (`?embed=1` скрывает
/// собственную шапку вьюера, просьба владельца 24.11). [onJs] вызывается,
/// когда страница вьюера догрузилась и отдала публичный API
/// `window.NexusViewer`; для платформ без моста (здесь это всё, кроме
/// Android) он не вызывается никогда.
Widget buildViewer(
  BuildContext context, {
  String? modelUrl,
  bool embed = true,
  void Function(StepViewerJs? js)? onJs,
}) {
  if (!_canEmbed) return stepViewerFallback(context);
  return _Viewer(modelUrl: modelUrl, embed: embed, onJs: onJs);
}

/// Вьюер внутри APK: открывает файлы с телефона (кнопка «Открыть STEP» —
/// теперь через `NexusViewer.openFile()`, владелец 24.11) и модели по
/// ссылке (`?url=…`, страница скачивает и разбирает локально).
class _Viewer extends StatefulWidget {
  final String? modelUrl;

  /// Приложение само рисует верхнюю панель — собственную шапку вьюера
  /// прячем параметром `?embed=1` (поддержка embed добавлена в
  /// assets/webview, просьба владельца 24.11).
  final bool embed;

  final void Function(StepViewerJs? js)? onJs;

  const _Viewer({this.modelUrl, required this.embed, this.onJs});

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
      // Шапку вьюера скрываем: вся навигация теперь в панели приложения
      // (единый экран вместо двух — просьба владельца 24.11).
      'embed': widget.embed ? '1' : '0',
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
