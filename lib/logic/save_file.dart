/// Сохранить файл пользователю: на телефоне — системное «Сохранить как»,
/// в браузере — обычная загрузка. `true` — сохранено.
library;

export 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';
