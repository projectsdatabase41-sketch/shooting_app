import 'dart:js_interop';

@JS('nexusWebPushToken')
external JSPromise<JSString?> _nexusWebPushToken(
    JSAny config, JSString vapidKey);

/// См. web/push-bridge.js — токен с воркером, зарегистрированным по пути сайта.
Future<String?> webPushToken(
    Map<String, String> config, String vapidKey) async {
  final r = await _nexusWebPushToken(config.jsify()!, vapidKey.toJS).toDart;
  return r?.toDart;
}

@JS('nexusPushEnv')
external JSString _nexusPushEnv();

/// 'ok' | 'ios-not-installed' | 'unsupported' — см. web/push-bridge.js.
String webPushEnv() => _nexusPushEnv().toDart;
