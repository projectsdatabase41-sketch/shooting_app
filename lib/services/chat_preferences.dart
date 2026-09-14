import 'package:flutter/material.dart';

import '../models/target_color_scheme.dart' show TargetColorScheme;
import 'local_db_service.dart';

/// Язык, на который переводить сообщения — список для экрана настроек,
/// системный язык устройства всегда показывается первым (см.
/// `ChatAppearanceScreen`).
class ChatLanguage {
  final String code;
  final String label;
  const ChatLanguage(this.code, this.label);
}

const List<ChatLanguage> chatLanguages = [
  ChatLanguage('ru', 'Русский'),
  ChatLanguage('en', 'English'),
  ChatLanguage('es', 'Español'),
  ChatLanguage('de', 'Deutsch'),
  ChatLanguage('fr', 'Français'),
  ChatLanguage('it', 'Italiano'),
  ChatLanguage('pt', 'Português'),
  ChatLanguage('tr', 'Türkçe'),
  ChatLanguage('pl', 'Polski'),
  ChatLanguage('uk', 'Українська'),
  ChatLanguage('kk', 'Қазақша'),
  ChatLanguage('zh', '中文'),
  ChatLanguage('ja', '日本語'),
  ChatLanguage('ko', '한국어'),
  ChatLanguage('ar', 'العربية'),
];

/// Готовые сочетания — быстро заполняют 4 цвета сразу (см.
/// `ChatPreferences.applyPreset`), а не отдельное самостоятельное
/// состояние: после ручной правки понятия "текущий пресет" не остаётся,
/// как и с любым другим редактируемым поверх шаблона оформлением.
///
/// Цвет текста — часть пресета, а не всегда белый: чистый белый на
/// ярком насыщенном фоне и в тёмной комнате (стрелковый тир, вечер)
/// сильнее устаёт глаза, чем тёплый неяркий оттенок с тем же контрастом.
class ChatBubblePreset {
  final String id;
  final String label;
  final Color mine;
  final Color other;
  final Color mineText;
  final Color otherText;

  const ChatBubblePreset({
    required this.id,
    required this.label,
    required this.mine,
    required this.other,
    this.mineText = Colors.white,
    this.otherText = Colors.white,
  });
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
    // Ночной — без синего и без чистого белого: меньше нагружает глаза
    // при чтении в темноте (перед стрельбой в помещении вечером и т.п.).
    ChatBubblePreset(
      id: 'night',
      label: 'Ночной',
      mine: Color(0xFF2B211B),
      other: Color(0xFF1E1E20),
      mineText: Color(0xFFE7B27A),
      otherText: Color(0xFFC9A87A),
    ),
    // Хаки — тактическая тема, в тон самому приложению.
    ChatBubblePreset(
      id: 'khaki',
      label: 'Хаки',
      mine: Color(0xFF4B5320),
      other: Color(0xFF3B3B2E),
      mineText: Color(0xFFEDEAE0),
      otherText: Color(0xFFD8CBB0),
    ),
    // Графит — низкий контраст без ярких цветов вообще, самый спокойный.
    ChatBubblePreset(
      id: 'graphite',
      label: 'Графит',
      mine: Color(0xFF565B66),
      other: Color(0xFF34383F),
      mineText: Color(0xFFF0F0F0),
      otherText: Color(0xFFC7CCD6),
    ),
    // Кофе — тёплая сепия вместо серого/синего.
    ChatBubblePreset(
      id: 'coffee',
      label: 'Кофе',
      mine: Color(0xFF6F4E37),
      other: Color(0xFF3E2F27),
      mineText: Color(0xFFF3E5D8),
      otherText: Color(0xFFD9C7B8),
    ),
    // Мята — приглушённый холодный цвет вместо насыщенного зелёного.
    ChatBubblePreset(
      id: 'mint',
      label: 'Мята',
      mine: Color(0xFF3E8E7E),
      other: Color(0xFF33403D),
      mineText: Color(0xFFEAFBF6),
      otherText: Color(0xFFB8D8CF),
    ),
  ];

  static const Color _defaultMine = Color(0xFF3D6BF2);
  static const Color _defaultOther = Color(0xFF3A3F4B);
  static const double _defaultShadow = 0.22;

  /// 'view_and_download' (по умолчанию) — у фото/файла есть кнопка
  /// "Сохранить"; 'view_only' — только просмотр в самом чате, без неё.
  /// Локальная настройка устройства (как и остальные ChatPreferences) —
  /// каждый решает сам для СВОЕГО экрана, не влияет на собеседника.
  bool get photoDownloadEnabled => _read('chat_photo_download') != '0';

  set photoDownloadEnabled(bool value) {
    _write('chat_photo_download', value ? '1' : '0');
    notifyListeners();
  }

  /// Ручной перевод одного сообщения (кнопка в меню долгого нажатия)
  /// доступен всегда — этот тумблер только про АВТОМАТИЧЕСКУЮ маску на
  /// каждое входящее сообщение сразу.
  bool get autoTranslate => _read('chat_translation_mode') == 'auto';

  set autoTranslate(bool value) {
    _write('chat_translation_mode', value ? 'auto' : 'off');
    notifyListeners();
  }

  /// Пустая строка — переводить на язык системы устройства (значение по
  /// умолчанию); иначе явно выбранный в настройках язык.
  String get translationLanguage => _read('chat_translation_language');

  set translationLanguage(String code) {
    _write('chat_translation_language', code);
    notifyListeners();
  }

  Color get mineBubbleColor => _readColor('chat_color_mine_bubble', _defaultMine);
  set mineBubbleColor(Color c) {
    _writeColor('chat_color_mine_bubble', c);
    notifyListeners();
  }

  Color get otherBubbleColor => _readColor('chat_color_other_bubble', _defaultOther);
  set otherBubbleColor(Color c) {
    _writeColor('chat_color_other_bubble', c);
    notifyListeners();
  }

  Color get mineTextColor => _readColor('chat_color_mine_text', Colors.white);
  set mineTextColor(Color c) {
    _writeColor('chat_color_mine_text', c);
    notifyListeners();
  }

  Color get otherTextColor => _readColor('chat_color_other_text', Colors.white);
  set otherTextColor(Color c) {
    _writeColor('chat_color_other_text', c);
    notifyListeners();
  }

  bool get shadowEnabled => _read('chat_shadow_enabled') != '0';
  set shadowEnabled(bool v) {
    _write('chat_shadow_enabled', v ? '1' : '0');
    notifyListeners();
  }

  /// 0..1 — насколько заметна тень под пузырём (пункт 7 списка правок).
  double get shadowIntensity {
    final raw = _read('chat_shadow_intensity');
    return raw.isEmpty ? _defaultShadow : (double.tryParse(raw) ?? _defaultShadow);
  }

  set shadowIntensity(double v) {
    _write('chat_shadow_intensity', v.clamp(0, 1).toStringAsFixed(2));
    notifyListeners();
  }

  /// "Удалить у себя" чужое сообщение общего чата — самого сообщения на
  /// сервере это не касается (RLS и так не даст удалить чужое), просто
  /// список id, скрытых локально на этом устройстве.
  Set<String> get hiddenGlobalIds {
    final raw = _read('chat_global_hidden_ids');
    return raw.isEmpty ? const {} : raw.split(',').toSet();
  }

  void hideGlobalMessage(String id) {
    _write('chat_global_hidden_ids', (hiddenGlobalIds..add(id)).join(','));
    notifyListeners();
  }

  /// Быстро заполняет все 4 цвета сразу — то, что раньше называлось
  /// "выбрать пресет".
  void applyPreset(ChatBubblePreset preset) {
    _writeColor('chat_color_mine_bubble', preset.mine);
    _writeColor('chat_color_other_bubble', preset.other);
    _writeColor('chat_color_mine_text', preset.mineText);
    _writeColor('chat_color_other_text', preset.otherText);
    notifyListeners();
  }

  Color _readColor(String column, Color fallback) {
    final raw = _read(column);
    if (raw.isEmpty) return fallback;
    try {
      return TargetColorScheme.hexToColor(raw);
    } catch (_) {
      return fallback;
    }
  }

  void _writeColor(String column, Color c) => _write(column, TargetColorScheme.colorToHex(c));

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
