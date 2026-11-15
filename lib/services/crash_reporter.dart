/// Crashlytics — только там, где он есть (Android/iOS/macOS).
///
/// У пакета `firebase_crashlytics` нет веб-платформы, поэтому импорт разделён
/// по условию сборки: на вебе берётся заглушка и пакет в сборку не попадает.
export 'crash_reporter_stub.dart' if (dart.library.io) 'crash_reporter_io.dart';
