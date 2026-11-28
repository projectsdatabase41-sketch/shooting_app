import 'package:flutter/foundation.dart';

import 'display_profile_stub.dart'
    if (dart.library.js_interop) 'display_profile_web.dart' as browser;

/// Профиль отображения (отзыв 28.11): веб с телефона, веб с компьютера и
/// приложение Android — это три разных режима вёрстки, хотя код один.
///
/// Раньше проверка была `kIsWeb || windows`, поэтому **веб с iPhone**
/// получал десктопную раскладку. Теперь профиль определяется по устройству:
///  * Android/iOS — мобильное приложение;
///  * веб в мобильном браузере (iPhone, Android, планшет с тачскрином) —
///    та же мобильная вёрстка, что в приложении, с редкими отличиями
///    (3D открывается отдельной вкладкой, нет системных разрешений);
///  * веб на компьютере и Windows/macOS/Linux-сборка — десктопная вёрстка.
enum DisplayProfile {
  android,
  ios,
  webPhone,
  webDesktop,
  windowsDesktop,
}

class Display {
  Display._();

  static DisplayProfile get profile {
    if (kIsWeb) {
      return browser.isMobileBrowser ? DisplayProfile.webPhone : DisplayProfile.webDesktop;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => DisplayProfile.ios,
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        DisplayProfile.windowsDesktop,
      _ => DisplayProfile.android,
    };
  }

  /// Мобильная вёрстка: Android, iOS и веб с телефона.
  static bool get isPhoneLayout =>
      profile == DisplayProfile.android ||
      profile == DisplayProfile.ios ||
      profile == DisplayProfile.webPhone;

  /// Десктопная вёрстка: веб на компьютере, Windows/macOS/Linux.
  static bool get isDesktopLayout => !isPhoneLayout;

  /// Подпись для настроек/диагностики.
  static String get label => switch (profile) {
        DisplayProfile.android => 'Android',
        DisplayProfile.ios => 'iOS',
        DisplayProfile.webPhone => 'Веб с телефона',
        DisplayProfile.webDesktop => 'Веб с компьютера',
        DisplayProfile.windowsDesktop => 'Windows/desktop',
      };
}
