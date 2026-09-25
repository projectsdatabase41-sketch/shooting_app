/// Файлы, память устройства и загрузка — только на нативных платформах.
/// В браузере локальная модель пока не поддерживается (см. заглушку).
library;

export 'local_ai_platform_io.dart' if (dart.library.js_interop) 'local_ai_platform_web.dart';
