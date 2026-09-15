import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/custom_service.dart';
import 'local_db_service.dart';

/// Хранилище плиток сторонних сервисов (раздел настроек "Сервисы") —
/// `ChangeNotifier`, чтобы `HomeShell` мог сразу обновить набор вкладок
/// главного экрана после добавления/удаления сервиса.
class CustomServicesRepository extends ChangeNotifier {
  final LocalDbService db;
  static const _uuid = Uuid();

  CustomServicesRepository(this.db);

  List<CustomService> list() {
    final rows = db.db.select('SELECT * FROM custom_services ORDER BY created_at');
    return rows.map(_fromRow).toList();
  }

  CustomService? byId(String id) {
    final rows = db.db.select('SELECT * FROM custom_services WHERE id = ?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  CustomService add({
    required String name,
    required String iconName,
    required String url,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) {
    final service = CustomService(
      id: _uuid.v4(),
      name: name,
      iconName: iconName,
      url: url,
      method: method,
      headers: headers,
      body: body,
    );
    db.db.execute(
      'INSERT INTO custom_services (id, name, icon_name, url, method, headers_json, body) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [service.id, service.name, service.iconName, service.url, service.method,
        service.headers.isEmpty ? null : jsonEncode(service.headers), service.body],
    );
    notifyListeners();
    return service;
  }

  void update(
    String id, {
    required String name,
    required String iconName,
    required String url,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) {
    db.db.execute(
      'UPDATE custom_services SET name = ?, icon_name = ?, url = ?, method = ?, headers_json = ?, body = ? WHERE id = ?',
      [name, iconName, url, method, headers.isEmpty ? null : jsonEncode(headers), body, id],
    );
    notifyListeners();
  }

  void delete(String id) {
    db.db.execute('DELETE FROM custom_services WHERE id = ?', [id]);
    notifyListeners();
  }

  CustomService _fromRow(Map<String, dynamic> row) {
    final headersJson = row['headers_json'] as String?;
    final headers = <String, String>{
      if (headersJson != null) for (final e in (jsonDecode(headersJson) as Map).entries) '${e.key}': '${e.value}',
    };
    return CustomService(
      id: row['id'] as String,
      name: row['name'] as String,
      iconName: row['icon_name'] as String,
      url: row['url'] as String,
      method: row['method'] as String,
      headers: headers,
      body: row['body'] as String?,
    );
  }
}
