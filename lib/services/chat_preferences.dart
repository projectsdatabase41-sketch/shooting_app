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
    ChatBubblePreset(id: 'classic', label: /*tr*/ 'Классика', mine: Color(0xFF3D6BF2), other: Color(0xFF3A3F4B)),
    ChatBubblePreset(id: 'forest', label: /*tr*/ 'Лес', mine: Color(0xFF2F8F5B), other: Color(0xFF33403A)),
    ChatBubblePreset(id: 'sunset', label: /*tr*/ 'Закат', mine: Color(0xFFD9633B), other: Color(0xFF40393F)),
    ChatBubblePreset(id: 'violet', label: /*tr*/ 'Фиолет', mine: Color(0xFF8256D0), other: Color(0xFF3B3A45)),
    // Ночной — без синего и без чистого белого: меньше нагружает глаза
    // при чтении в темноте (перед стрельбой в помещении вечером и т.п.).
    ChatBubblePreset(
      id: 'night',
      label: /*tr*/ 'Ночной',
      mine: Color(0xFF2B211B),
      other: Color(0xFF1E1E20),
      mineText: Color(0xFFE7B27A),
      otherText: Color(0xFFC9A87A),
    ),
    // Хаки — тактическая тема, в тон самому приложению.
    ChatBubblePreset(
      id: 'khaki',
      label: /*tr*/ 'Хаки',
      mine: Color(0xFF4B5320),
      other: Color(0xFF3B3B2E),
      mineText: Color(0xFFEDEAE0),
      otherText: Color(0xFFD8CBB0),
    ),
    // Графит — низкий контраст без ярких цветов вообще, самый спокойный.
    ChatBubblePreset(
      id: 'graphite',
      label: /*tr*/ 'Графит',
      mine: Color(0xFF565B66),
      other: Color(0xFF34383F),
      mineText: Color(0xFFF0F0F0),
      otherText: Color(0xFFC7CCD6),
    ),
    // Кофе — тёплая сепия вместо серого/синего.
    ChatBubblePreset(
      id: 'coffee',
      label: /*tr*/ 'Кофе',
      mine: Color(0xFF6F4E37),
      other: Color(0xFF3E2F27),
      mineText: Color(0xFFF3E5D8),
      otherText: Color(0xFFD9C7B8),
    ),
    // Мята — приглушённый холодный цвет вместо насыщенного зелёного.
    ChatBubblePreset(
      id: 'mint',
      label: /*tr*/ 'Мята',
      mine: Color(0xFF3E8E7E),
      other: Color(0xFF33403D),
      mineText: Color(0xFFEAFBF6),
      otherText: Color(0xFFB8D8CF),
    ),
  ];

  static const Color _defaultMine = Color(0xFF3D6BF2);
  static const Color _defaultOther = Color(0xFF3A3F4B);
  static const double _defaultShadow = 0.22;

  /// Разрешает ли пользователь скачивание СВОИХ отправленных фото/файлов
  /// (решение пользователя: это выбор ОТПРАВИТЕЛЯ, а не получателя —
  /// значение передаётся вместе с сообщением на отправке, см.
  /// `ChatSyncService.sendAttachment`/`ChatGlobalService.sendAttachment`,
  /// и хранится на самом сообщении, `ChatMessage.downloadAllowed`).
  /// 'all' (по умолчанию, для совместимости со старым единственным
  /// переключателем) — везде; 'personal' — только в личных чатах;
  /// 'off' — нигде.
  String get photoDownloadMode {
    final raw = _read('chat_photo_download');
    return raw.isEmpty || raw == '1' ? 'all' : raw;
  }

  set photoDownloadMode(String mode) {
    _write('chat_photo_download', mode);
    notifyListeners();
  }

  /// Значение для конкретного отправляемого сообщения — вычисляется на
  /// отправке и дальше едет вместе с ним, получатель уже смотрит только
  /// на это поле, а не заново спрашивает настройки отправителя.
  bool downloadAllowedFor({required bool isPersonal}) {
    switch (photoDownloadMode) {
      case 'off':
        return false;
      case 'personal':
        return isPersonal;
      default:
        return true;
    }
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

  /// Автоперевод конкретного диалога (меню ⋮ в переписке). Явный выбор
  /// диалога важнее общей настройки [autoTranslate].
  bool autoTranslateFor(String contactId) {
    final v = _translateOverrides[contactId];
    return v ?? autoTranslate;
  }

  void setAutoTranslateFor(String contactId, bool on) {
    final map = _translateOverrides..[contactId] = on;
    _write('chat_auto_translate_ids', [for (final e in map.entries) '${e.key}:${e.value ? 1 : 0}'].join(','));
    notifyListeners();
  }

  Map<String, bool> get _translateOverrides {
    final raw = _read('chat_auto_translate_ids');
    return {
      for (final part in raw.split(','))
        if (part.contains(':')) part.substring(0, part.lastIndexOf(':')): part.endsWith(':1'),
    };
  }

  /// Беззвучный диалог — колокольчик в панели собеседника. Push-уведомление
  /// о сообщении из него не показывается (см. push_service.dart).
  bool mutedFor(String contactId) => _read('chat_muted_ids').split(',').contains(contactId);

  void setMutedFor(String contactId, bool muted) {
    final ids = _read('chat_muted_ids').split(',').where((e) => e.isNotEmpty && e != contactId).toList();
    if (muted) ids.add(contactId);
    _write('chat_muted_ids', ids.join(','));
    notifyListeners();
  }

  /// Колонок в плитках фото панели собеседника (щипок 1–8, общее для всех чатов).
  int get mediaColumns => (int.tryParse(_read('chat_media_columns')) ?? 4).clamp(1, 8);
  set mediaColumns(int v) => _write('chat_media_columns', '${v.clamp(1, 8)}');

  /// Размер текста в переписке (множитель 0.85–1.3).
  double get fontScale => (double.tryParse(_read('chat_font_scale')) ?? 1.0).clamp(0.85, 1.3);
  set fontScale(double v) {
    _write('chat_font_scale', v.clamp(0.85, 1.3).toStringAsFixed(2));
    notifyListeners();
  }

  /// Скругление пузырей, px (4–28).
  double get bubbleRadius => (double.tryParse(_read('chat_bubble_radius')) ?? 16).clamp(4, 28);
  set bubbleRadius(double v) {
    _write('chat_bubble_radius', v.clamp(4, 28).toStringAsFixed(0));
    notifyListeners();
  }

  /// Фон переписки: '' — как у приложения, id из [chatWallpapers] или '#RRGGBB'.
  String get wallpaper => _read('chat_wallpaper');
  set wallpaper(String v) {
    _write('chat_wallpaper', v);
    notifyListeners();
  }

  /// Готовые фоны (градиенты) — id: (название, цвета).
  static const Map<String, (String, List<Color>)> chatWallpapers = {
    'dusk': ('Закат', [Color(0xFF2B1B3D), Color(0xFF6B3A5B)]),
    'ocean': ('Океан', [Color(0xFF0F2A44), Color(0xFF1F5E7A)]),
    'forest': ('Лес', [Color(0xFF16291E), Color(0xFF2F5238)]),
    'sand': ('Песок', [Color(0xFFF3E7D3), Color(0xFFE2C9A6)]),
    'mint': ('Мята', [Color(0xFFE3F4EE), Color(0xFFBFE3D6)]),
    'graphite': ('Графит', [Color(0xFF1E2126), Color(0xFF34383F)]),
  };

  /// Декорация фона переписки; null — фон приложения.
  BoxDecoration? get wallpaperDecoration {
    final w = wallpaper;
    if (w.isEmpty) return null;
    final preset = chatWallpapers[w];
    if (preset != null) {
      return BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: preset.$2),
      );
    }
    return TargetColorScheme.isValidHex(w) ? BoxDecoration(color: TargetColorScheme.hexToColor(w)) : null;
  }

  /// Контакт-тренер для кнопки «Позвать тренера» на экране тренировки.
  String get coachContactId => _read('chat_coach_contact_id');
  set coachContactId(String id) {
    _write('chat_coach_contact_id', id);
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
