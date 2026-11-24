import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Каталог 3D-моделей с Google Drive.
///
/// Владелец 24.11: «Модели должны лететь с гугл диска. Я открыл
/// возможность прочитывать по ссылке эти файлы. Сами файлы не
/// скачиваются на устройство и просто просматриваются методом
/// замещения URL» — поэтому:
///
/// - сам каталог (какой файл лежит в какой папке Drive) собран заранее
///   в ассет `assets/models/catalog.json` (дерево 20 категорий, 329
///   .stp): список моделей читается из ассета, ни воркер, ни Drive API
///   при открытии экрана не вызываются;
/// - ссылка на модель — прямая публичная `drive.usercontent.google.com`
///   (проверено: 200 и CORS `*`), её отдаю готовой — вьюер читает файл
///   по URL и разбирает на устройстве, ничего не сохраняя в файловую
///   систему;
/// - превью на Drive пока нет (`previewId == null`) — вместо картинки
///   карточка-заглушка; когда появятся, достаточно заполнить
///   `previewId` в `catalog.json`, код не меняется.
class DriveModelsCatalog {
  DriveModelsCatalog._();

  /// Записи каталога (в порядке следования в ассете — уже по категориям,
  /// внутри категории по `order`).
  static List<DriveCatalogModel> items = const [];

  /// True — ассет прочитан и распарсен, можно показывать сетку.
  static bool get isLoaded => _loaded;
  static bool _loaded = false;

  /// Код последней ошибки разбора/чтения ассета. Показывается только
  /// в режиме разработчика (`friendlyErrorDevMode`) — см.
  /// `lib/logic/friendly_error.dart`.
  static String? lastErrorCode;

  /// Ассет с каталогом (объявлен в pubspec.yaml рядом с assets/webview/).
  static const _assetPath = 'assets/models/catalog.json';

  /// Формулы ссылок собраны здесь и наружу не выходят: экраны получают
  /// готовый адрес, URL нигде не печатается и не логируется.

  /// Модель (.stp): прямая публичная ссылка на скачивание с Drive.
  /// Проверено владельцем: ответ 200 и CORS `*`, при этом вьюер читает
  /// файл по URL в память — на диск ничего не попадает (владелец 24.11:
  /// «не скачиваются на устройство … методом замещения URL»).
  static String modelUrl(String id) =>
      'https://drive.usercontent.google.com/download?id=$id&export=download';

  /// Превью: публичная ссылка на картинку через хостинг миниатюр Google
  /// (работает только если файл картинка доступен по ссылке).
  static String previewUrl(String previewId) =>
      'https://lh3.googleusercontent.com/d/$previewId=w600';

  /// Читает каталог из ассета. Не бросает исключений: при ошибке
  /// заполняет [lastErrorCode] и оставляет прошлый список нетронутым
  /// (в памяти после успешной загрузки он остаётся навсегда — данные
  /// уже локальные, сети тут нет).
  static Future<bool> load() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final data = jsonDecode(raw);
      if (data is! Map || data['items'] is! List) {
        lastErrorCode = 'bad catalog payload';
        return false;
      }
      final list = _parseList(data['items'] as List);
      if (list.isEmpty) {
        lastErrorCode = 'catalog is empty';
        return false;
      }
      items = list;
      _loaded = true;
      lastErrorCode = null;
      return true;
    } catch (e) {
      // Битый JSON или ассет не попал в сборку: понятный текст покажет
      // экран каталога, код — только разработчику (friendlyErrorDevMode).
      lastErrorCode = 'asset ${e.runtimeType}';
      return _loaded; // если раньше уже загружались — список остаётся
    }
  }

  static List<DriveCatalogModel> _parseList(List raw) {
    final parsed = <DriveCatalogModel>[];
    for (final m in raw) {
      if (m is! Map) continue;
      final id = '${m['id']}';
      final name = '${m['name']}';
      if (id.isEmpty || id == 'null' || name.isEmpty || name == 'null') {
        continue;
      }
      final rawPreview = m['previewId'];
      parsed.add(DriveCatalogModel(
        id: id,
        name: name,
        fileName: '${m['fileName'] ?? ''}',
        category: '${m['category'] ?? ''}',
        path: '${m['path'] ?? ''}',
        previewId: rawPreview == null || '$rawPreview'.isEmpty
            ? null
            : '$rawPreview',
        order: m['order'] is num ? (m['order'] as num).toInt() : 0,
      ));
    }
    return parsed;
  }
}

/// Одна запись каталога Drive: элемент из `assets/models/catalog.json`.
class DriveCatalogModel {
  /// Идентификатор файла .stp на Google Drive (из него строится ссылка
  /// модели через [DriveModelsCatalog.modelUrl]).
  final String id;

  /// Отображаемое название (имя файла без расширения).
  final String name;

  /// Имя файла в Drive-папке, например `G1.stp` (для поиска).
  final String fileName;

  /// Название категории (= имя подпапки Drive).
  final String category;

  /// Путь внутри Drive-дерева, например `Категория/G1.stp`.
  final String path;

  /// Идентификатор картинки-превью на Drive; null — превью пока нет и
  /// карточка рисуется заглушкой (иконка + название, владелец 24.11):
  /// картинки на Drive пока не размещены.
  final String? previewId;

  final int order;

  const DriveCatalogModel({
    required this.id,
    required this.name,
    this.fileName = '',
    this.category = '',
    this.path = '',
    this.previewId,
    this.order = 0,
  });

  /// Есть ли превью на Drive (пока картинки не размещены — везде null).
  bool get hasPreview =>
      previewId != null && previewId!.trim().isNotEmpty;
}
