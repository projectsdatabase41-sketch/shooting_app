/// Модель, которую можно скачать для работы ИИ без интернета.
class LocalModelInfo {
  final String id;
  final String name;
  final String tier;
  final String note;
  final String url;
  final int sizeBytes;
  final String sha256;

  /// Сколько ОЗУ нужно устройству, чтобы модель работала без вылетов.
  final int minRamGb;

  /// Qwen3 умеет «думать вслух» — для коротких ответов это выключаем.
  final bool hasThinking;

  /// Проектор изображений — у моделей «со зрением»: та же модель и пишет
  /// текст, и ищет пробоины на фото (одна модель вместо двух).
  final LocalModelInfo? projector;
  bool get sees => projector != null;

  const LocalModelInfo({
    required this.id,
    required this.name,
    required this.tier,
    required this.note,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
    required this.minRamGb,
    this.hasThinking = false,
    this.projector,
  });

  /// Оба файла вместе — для подсказок о размере.
  int get totalBytes => sizeBytes + (projector?.sizeBytes ?? 0);

  String get fileName => '$id.gguf';
}

/// От минимума (любой телефон) до максимума (ПК / флагман). Больше 8B на
/// телефоне не берём: слишком медленно и греется.
/// ponytail: каталог в коде; перенести в удалённый конфиг, когда модели
/// начнут меняться чаще выпусков приложения.
const List<LocalModelInfo> localModelCatalog = [
  LocalModelInfo(
    id: 'qwen2.5-0.5b',
    name: 'Qwen2.5 0.5B',
    tier: /*tr*/ 'Минимум',
    note: /*tr*/ 'Любой телефон. Только самое простое: путает смысл и вставляет китайские слова',
    url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sizeBytes: 491400032,
    sha256: '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
    minRamGb: 3,
  ),
  LocalModelInfo(
    id: 'qwen2.5-1.5b',
    name: 'Qwen2.5 1.5B',
    tier: /*tr*/ 'Лёгкая',
    note: /*tr*/ 'Средний телефон. Заметки и служебные задачи',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1117320736,
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
    minRamGb: 4,
  ),
  LocalModelInfo(
    id: 'qwen2.5-3b',
    name: 'Qwen2.5 3B',
    tier: /*tr*/ 'Средняя',
    note: /*tr*/ 'Хороший телефон. Почти все служебные задачи',
    url: 'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
    sizeBytes: 2104932768,
    sha256: '626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d',
    minRamGb: 6,
  ),
  LocalModelInfo(
    id: 'qwen3-4b',
    name: 'Qwen3 4B',
    tier: /*tr*/ 'Средняя+',
    note: /*tr*/ 'Флагман или ПК. Лучше понимает задачи',
    url: 'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf',
    sizeBytes: 2497280256,
    sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    minRamGb: 8,
    hasThinking: true,
  ),
  LocalModelInfo(
    id: 'qwen2.5-7b',
    name: 'Qwen2.5 7B',
    tier: /*tr*/ 'Максимум',
    note: /*tr*/ 'ПК или телефон с 12+ ГБ. Близко к бесплатным облачным',
    url: 'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    sizeBytes: 4683074240,
    sha256: '65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423',
    minRamGb: 12,
  ),
  // Со зрением: текст + поиск пробоин на фото мишени.
  LocalModelInfo(
    id: 'qwen2.5-vl-3b',
    name: 'Qwen2.5-VL 3B',
    tier: /*tr*/ 'Видит фото',
    note: /*tr*/ 'Хороший телефон. Текст на уровне Qwen2.5 3B + находит пробоины на фото мишени',
    url: 'https://huggingface.co/ggml-org/Qwen2.5-VL-3B-Instruct-GGUF/resolve/main/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf',
    sizeBytes: 1929901056,
    sha256: 'd02fe9b69ad8cadbbd228e387667af66612c44bed29ffc8eb1e7caf9ac486c12',
    minRamGb: 6,
    projector: LocalModelInfo(
      id: 'qwen2.5-vl-3b-mmproj',
      name: 'зрение',
      tier: '',
      note: '',
      url: 'https://huggingface.co/ggml-org/Qwen2.5-VL-3B-Instruct-GGUF/resolve/main/mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf',
      sizeBytes: 844757728,
      sha256: '980c9b2f78c04e6cff93d277ada09e768394f112d75db3b4e9dea8a69f9fb904',
      minRamGb: 0,
    ),
  ),
  LocalModelInfo(
    id: 'smolvlm-500m',
    name: 'SmolVLM 500M',
    tier: /*tr*/ 'Видит фото (лёгкая)',
    note: /*tr*/ 'Любой телефон. Пробоины находит грубо, текст по-русски слабый',
    url: 'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/SmolVLM-500M-Instruct-Q8_0.gguf',
    sizeBytes: 436806912,
    sha256: '9d4612de6a42214499e301494a3ecc2be0abdd9de44e663bda63f1152fad1bf4',
    minRamGb: 3,
    projector: LocalModelInfo(
      id: 'smolvlm-500m-mmproj',
      name: 'зрение',
      tier: '',
      note: '',
      url: 'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-500M-Instruct-Q8_0.gguf',
      sizeBytes: 108783360,
      sha256: 'd1eb8b6b23979205fdf63703ed10f788131a3f812c7b1f72e0119d5d81295150',
      minRamGb: 0,
    ),
  ),
];

LocalModelInfo? localModelById(String id) {
  for (final m in localModelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}
