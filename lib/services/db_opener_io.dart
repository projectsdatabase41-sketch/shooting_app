import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

/// Нативная реализация: обычный файл sqlite в служебной папке
/// приложения. Так работали Windows и Android до появления веб-сборки —
/// поведение не изменилось, код просто переехал сюда из
/// `LocalDbService`.
Future<CommonDatabase> openAppDatabase({String? overridePath}) async {
  final path = overridePath ?? await _defaultPath();
  return sqlite3.open(path);
}

Future<String> _defaultPath() async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'shooting_app.sqlite3');
}

/// В браузере запись в IndexedDB идёт асинхронно, поэтому там нужен
/// явный сброс на диск. На нативных платформах sqlite пишет в файл сам,
/// и делать здесь нечего — метод существует только ради общего
/// интерфейса с веб-версией.
Future<void> flushDatabase() async {}
