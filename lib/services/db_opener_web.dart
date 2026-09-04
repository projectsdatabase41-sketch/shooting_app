import 'package:sqlite3/common.dart';
import 'package:sqlite3/wasm.dart';

/// Веб-реализация: тот же sqlite, только собранный в WebAssembly, а
/// файл базы лежит в IndexedDB браузера.
///
/// Почему именно так, а не «перепишем на localStorage»: всё хранилище
/// приложения — это обычный SQL (`AppDataStore`, `CommentsRepository`,
/// настройки цветов и ассистента). Замена движка означала бы переписать
/// каждый запрос и завести второй набор ошибок, который живёт только в
/// браузере. С wasm-сборкой SQL остаётся буква в букву тот же самый,
/// включая транзакции и внешние ключи.
///
/// ВАЖНО: рядом должен лежать файл `web/sqlite3.wasm` — сам движок.
/// Он не приходит с пакетом (иначе бы весил в каждой мобильной сборке),
/// его кладут в папку `web` вручную. Без него приложение в браузере
/// не стартует и честно скажет об этом в консоли.
///
/// Данные живут в IndexedDB конкретного браузера на конкретном
/// устройстве: другой браузер — другая база, очистка данных сайта —
/// база стёрта. Для веб-версии это нормально и ровно поэтому нужна
/// синхронизация с Supabase; локальная база в браузере — кэш, а не
/// сейф.
Future<CommonDatabase> openAppDatabase({String? overridePath}) async {
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));

  // Виртуальная файловая система поверх IndexedDB. `dbName` — имя
  // хранилища в браузере, а не имя файла базы внутри него.
  _fileSystem = await IndexedDbFileSystem.open(dbName: 'shooting_app');
  sqlite.registerVirtualFileSystem(_fileSystem!, makeDefault: true);

  return sqlite.open(overridePath ?? '/shooting_app.sqlite3');
}

IndexedDbFileSystem? _fileSystem;

/// Сбрасывает записанное в IndexedDB.
///
/// В браузере запись идёт через асинхронный слой, и между «sqlite
/// записал» и «браузер сохранил» есть зазор. Если вкладку закрыть
/// внутри этого зазора, последние изменения пропадут. Поэтому после
/// значимых операций вызывается явный сброс.
Future<void> flushDatabase() async {
  await _fileSystem?.flush();
}
