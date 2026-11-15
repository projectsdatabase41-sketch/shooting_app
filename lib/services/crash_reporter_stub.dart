/// Заглушка для платформ без Crashlytics (веб): API то же, действий нет.
class CrashReporter {
  static bool get enabled => false;

  static Future<void> init() async {}

  static void breadcrumb(String step) {}
}
