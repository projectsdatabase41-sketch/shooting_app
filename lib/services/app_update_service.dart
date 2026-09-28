/// Проверка и установка обновления APK одной кнопкой (настройки → «Проверить
/// обновления») — только на Android, см. заглушку для остальных платформ.
library;

export 'app_update_service_io.dart' if (dart.library.js_interop) 'app_update_service_web.dart';
