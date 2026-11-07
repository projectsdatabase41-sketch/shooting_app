import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'step_viewer_common.dart';

/// Синтетический https-origin: `androidx.webkit.WebViewAssetLoader` отдаёт
/// файлы из APK под ним. Только так работают ES-модули, importmap и
/// загрузка wasm — на `file:///android_asset/…` браузер это запрещает.
const _viewerBase =
    'https://appassets.androidplatform.net/assets/flutter_assets/assets/webview/';

/// Встроенный показ возможен только там, где есть WebView и AssetLoader.
bool get _canEmbed => defaultTargetPlatform == TargetPlatform.android;

Widget buildViewer(BuildContext context, {String? modelUrl}) {
  if (!_canEmbed) return stepViewerFallback(context);
  return _Viewer(modelUrl: modelUrl);
}

/// Вьюер внутри APK: открывает файлы с телефона (кнопка «Открыть STEP» —
/// системный выбор файла поднимает сам WebView) и модели по ссылке
/// (`?url=…`, страница скачивает и разбирает локально).
class _Viewer extends StatefulWidget {
  final String? modelUrl;
  const _Viewer({this.modelUrl});

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  double _progress = 0;
  String? _error;

  Uri get _initialUrl {
    final base = Uri.parse('${_viewerBase}index.html');
    final url = widget.modelUrl;
    if (url == null || url.isEmpty) return base;
    return base.replace(queryParameters: {'url': url});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InAppWebView(
          key: ValueKey(_initialUrl.toString()),
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
            if (mounted) setState(() => _error = error.description);
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
