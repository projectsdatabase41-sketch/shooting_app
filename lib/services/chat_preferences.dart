import 'package:flutter/material.dart';

import 'local_db_service.dart';

/// Когда переводить входящие сообщения (пункт 4 списка правок):
/// - [off] — никогда, кнопки перевода нет вообще;
/// - [manual] — кнопка "Перевести" в меню долгого нажатия на сообщение;
/// - [auto] — перевод сразу, для каждого сообщения не на языке системы.
enum ChatTranslationMode { off, manual, auto }

/// Оформление пузырей чата — цвета "своих"/"чужих" сообщений. Тени и
/// лёгкий 3D-градиент (пункт 7) применяются всегда поверх любого
/// пресета, здесь только базовые цвета.
class ChatBubblePreset {
  final String id;
  final String label;
  final Color mine;
  final Color other;

  const ChatBubblePreset({required this.id, required this.label, required this.mine, required this.other});
}

/// Настройки чата, не завязанные на конкретный аккаунт (тот же экран
/// живёт в личном/общем чате независимо от входа) — хранятся локально,
/// как и все остальные настройки приложения, в `project_settings`.
class ChatPreferences extends ChangeNotifier {
  final LocalDbService db;
  ChatPreferences(this.db);

  static const List<ChatBubblePreset> presets = [
    ChatBubblePreset(id: 'classic', label: 'Классика', mine: Color(0xFF3D6BF2), other: Color(0xFF3A3F4B)),
    ChatBubblePreset(id: 'forest', label: 'Лес', mine: Color(0xFF2F8F5B), other: Color(0xFF33403A)),
    ChatBubblePreset(id: 'sunset', label: 'Закат', mine: Color(0xFFD9633B), other: Color(0xFF40393F)),
    ChatBubblePreset(id: 'violet', label: 'Фиолет', mine: Color(0xFF8256D0), other: Color(0xFF3B3A45)),
  ];

  ChatTranslationMode get translationMode {
    switch (_read('chat_translation_mode')) {
      case 'manual':
        return ChatTranslationMode.manual;
      case 'auto':
        return ChatTranslationMode.auto;
      default:
        return ChatTranslationMode.off;
    }
  }

  set translationMode(ChatTranslationMode mode) {
    _write('chat_translation_mode', mode.name);
    notifyListeners();
  }

  ChatBubblePreset get bubblePreset {
    final id = _read('chat_bubble_preset');
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }

  set bubblePreset(ChatBubblePreset preset) {
    _write('chat_bubble_preset', preset.id);
    notifyListeners();
  }

  String _read(String column) {
    final rows = db.db.select('SELECT $column FROM project_settings WHERE id = 1');
    if (rows.isEmpty) return '';
    return '${rows.first[column] ?? ''}';
  }

  void _write(String column, String value) {
    db.db.execute(
      'INSERT INTO project_settings (id, $column) VALUES (1, ?) '
      'ON CONFLICT(id) DO UPDATE SET $column = excluded.$column',
      [value],
    );
  }
}
