import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/display_profile.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android — мобильная вёрстка', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(Display.profile, DisplayProfile.android);
    expect(Display.isPhoneLayout, isTrue);
    expect(Display.isDesktopLayout, isFalse);
  });

  test('iOS — мобильная вёрстка', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(Display.profile, DisplayProfile.ios);
    expect(Display.isPhoneLayout, isTrue);
  });

  test('Windows — десктопная вёрстка', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(Display.profile, DisplayProfile.windowsDesktop);
    expect(Display.isDesktopLayout, isTrue);
  });

  test('macOS и Linux — тоже десктоп', () {
    for (final p in [TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = p;
      expect(Display.isDesktopLayout, isTrue);
    }
  });
}
