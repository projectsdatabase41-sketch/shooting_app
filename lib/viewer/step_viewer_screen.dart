import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/drive_models_catalog.dart' show DriveModelsCatalog;
import '../services/soft_input.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_route.dart';
import 'models_catalog_screen.dart' show ModelsCatalogBody;
import 'step_viewer_common.dart';
import 'step_viewer_io.dart'
    if (dart.library.html) 'step_viewer_web.dart' as impl;

/// Просмотр 3D-моделей (STEP/GLB).
///
/// Замечания владельца 24.11, п.1 возвращаем «как было ранее»:
///
/// - вьюер открывается БЕЗ `?embed=1` — своя шапка вьюера видна, панели
///   «Масса»/«Настройки» опущены под ней и больше не перекрываются;
/// - Flutter-шапка с кнопками «Рёбра»/«Свойства»/«Отображение» убрана —
///   эти функции снова в шапке самого вьюера (там же заливка/прозрачность
///   в панели массы);
/// - «Каталог»: на Android — первая кнопка слева в шапке самого вьюера
///   (через мост `NexusApp.openCatalog` → JS-хендлер, см.
///   step_viewer_io.dart), на вебе — маленькая FAB внизу справа, шапку
///   не перекрывает.
///
/// Сам вьюер — статический сайт в `assets/webview/` (three.js +
/// OpenCascade в wasm), он же копируется в APK. Файл выбирается с
/// телефона или открывается по ссылке; разбор идёт на устройстве, файл
/// никуда не отправляется.
class StepViewerScreen extends StatefulWidget {
  /// Модель, открытая по ссылке (или переданная из другого экрана).
  final String? modelUrl;

  const StepViewerScreen({super.key, this.modelUrl});

  @override
  State<StepViewerScreen> createState() => _StepViewerScreenState();
}

class _StepViewerScreenState extends State<StepViewerScreen> {
  // Отзыв 25.11 (54136573): адрес модели не показываем. Ссылка/Drive-id
  // живут только в [_url] и уходят напрямую в загрузку (страница вьюера
  // с ?url= или мост NexusViewer.load) — в интерфейсе их нет: заголовок
  // шапки нейтральный («3D-модель»), подписей с URL/именем файла нет
  // (Text, tooltip, Semantics проверены); ошибки WebView приходят уже
  // с вырезанными ссылками (_redactLinks в step_viewer_io.dart).
  String? _url;

  /// Мост к `window.NexusViewer`. Появляется, когда страница вьюера
  /// догрузилась и отдала публичный API (Android); на вебе мостов нет —
  /// загрузка модели там идёт через пересоздание страницы с `?url=`.
  StepViewerJs? _js;

  /// Сколько раз страница вьюера пересоздавалась. Нужен только как ключ
  /// тела: WebView нельзя перенаправить снаружи, поэтому проще, чтобы
  /// страница открылась заново с параметром `?url=`.
  int _pageVersion = 0;

  /// Окошко каталога уже открыто (владелец 24.11): кнопка «Каталог» в
  /// шапке вьюера может прилететь повторно (ещё один тап) — повторное
  /// `showDialog` поверх окошка не нужно.
  bool _catalogOpen = false;

  @override
  void initState() {
    super.initState();
    _url = widget.modelUrl; // открытие по modelUrl извне не ломаем
    // Отзыв 26.11: клавиатура дёргала 3D-сцену. Пока экран открыт, окно
    // Android не сжимается под клавиатуру (см. lib/services/soft_input.dart).
    SoftInput.adjustNothing();
  }

  @override
  void dispose() {
    SoftInput.adjustResize();
    super.dispose();
  }

  bool get _hasBridge =>
      !kIsWeb; // мост есть только на Android (WebView-контроллер)

  /// Загрузить модель: выбор из каталога НЕ пересоздаёт экран — сначала
  /// пробуем `NexusViewer.load(url)` в уже открытом вьюере; не готов —
  /// открываем страницу заново с `?url=` (владелец 24.11).
  Future<void> _loadModel(String url) async {
    final js = _js;
    if (_hasBridge && js != null && await js.loadModel(url)) {
      if (!mounted) return;
      setState(() => _url = url);
      return;
    }
    // Вьюер ещё не готов (страница грузится) или моста нет: открываем
    // страницу с параметром url — вьюер сам скачает и соберёт модель.
    if (mounted) {
      setState(() {
        _url = url;
        _pageVersion++;
        _js = null;
      });
    }
  }

  // ---- Окошко каталога (почти на весь экран, владелец 24.11) ------------

  Future<void> _openCatalog() async {
    if (_catalogOpen) return;
    if (mounted) setState(() => _catalogOpen = true);
    try {
      final cs = Theme.of(context).colorScheme;
      await showDialog<void>(
        context: context,
        barrierColor: Theme.of(context).brightness == Brightness.dark
            ? Colors.black54
            : Colors.black26,
        // Клавиатура НЕ сжимает диалог: при открытии она пересчитывала
        // высоту всего окошка и список «сворачивался» (отзыв 140cf047).
        // Теперь диалог стоит на месте, клавиатура просто накрывает его
        // нижнюю часть — поиск вверху остаётся доступным.
        builder: (ctx) => MediaQuery.removeViewInsets(
          context: ctx,
          removeBottom: true,
          child: Dialog(
            backgroundColor: cs.surface,
            // Радиус и рамка — из темы, как у остальных карточек приложения.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: cs.outlineVariant),
            ),
            // «Почти на весь экран»: 92% высоты, 96% ширины (владелец 24.11).
            insetPadding: EdgeInsets.symmetric(
              vertical: MediaQuery.sizeOf(ctx).height * 0.04,
              horizontal: MediaQuery.sizeOf(ctx).width * 0.02,
            ),
            child: SizedBox(
              width: MediaQuery.sizeOf(ctx).width * 0.96,
              height: MediaQuery.sizeOf(ctx).height * 0.92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Свой заголовок окошка: без шапок-страниц снаружи (внутри
                  // каталога-тела — только поиск, категории и сетка).
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('Каталог моделей'),
                            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        GlassCircleButton(
                          tooltip: tr('Открыть по ссылке'),
                          icon: const Icon(Icons.link),
                          onTap: _openUrlDialog,
                        ),
                        GlassCircleButton(
                          tooltip: tr('Закрыть'),
                          icon: const Icon(Icons.close),
                          onTap: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ModelsCatalogBody(
                      onPick: (model) {
                        Navigator.of(ctx).pop(); // закрыть окошко
                        // Модель «летит с Google Drive» (владелец 24.11):
                        // вьюер читает файл по URL с Drive (замещение URL),
                        // на устройство ничего не сохраняется.
                        _loadModel(DriveModelsCatalog.modelUrl(model.id));
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _catalogOpen = false);
    }
  }

  // ---- Открытие по ссылке (отзыв 081dffa7: «пропала возможность открыть
  // с помощью url») -------------------------------------------------------

  Future<void> _openUrlDialog() async {
    final ctrl = TextEditingController();
    String? error;
    final url = await showGlassDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(tr('Открыть модель по ссылке')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: tr('Ссылка на .stp / .step / .glb'),
                hintText: 'https://…',
              ),
              onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: () {
                final raw = ctrl.text.trim();
                final uri = Uri.tryParse(raw);
                if (raw.isEmpty ||
                    uri == null ||
                    !(uri.isScheme('http') || uri.isScheme('https'))) {
                  setS(() => error = tr('Нужна полная ссылка http:// или https://'));
                  return;
                }
                Navigator.pop(ctx, raw);
              },
              child: Text(tr('Открыть')),
            ),
          ],
        ),
      ),
    );
    if (url != null && url.isNotEmpty) await _loadModel(url);
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop == true;

    return Scaffold(
      // Клавиатура не должна сжимать WebView: при каждом кадре открытия она
      // пересчитывала размер и перерисовывала 3D-сцену (отзыв 24.11,
      // п.2 — «дёргание» интерфейса при открытии клавиатуры).
      resizeToAvoidBottomInset: false,
      // Отзыв 25.11 (102eae18): обои рисуем на всю высоту, включая
      // статус-бар и зону под прозрачной шапкой; раньше тело с фоном
      // начиналось под шапкой, и эта полоса была залита цветом
      // персонализации. Отступ сверху — только у содержимого (см. body).
      extendBodyBehindAppBar: true,
      // Шапка нужна только когда экран открыт отдельной страницей (старый
      // путь из каталога): тогда без кнопки «назад» вернуться нельзя. В
      // основном пути — вкладка общего меню, шапка-страница не нужна, и
      // вьюер со своей шапкой занимает весь экран целиком.
      appBar: canPop
          ? PreferredSize(
              preferredSize: const Size.fromHeight(GlassHeader.height),
              child: GlassHeader(title: Text(tr('3D-модель'))),
            )
          : null,
      body: AppBackdrop(
        kind: 'settings',
        // Отступ сверху (статус-бар + шапка) оставляем только контенту:
        // страница вьюера сидит под шапкой, как раньше, а фон заходит выше.
        child: Padding(
          padding: canPop
              ? EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top +
                      GlassHeader.height)
              : EdgeInsets.zero,
          child: Offstage(
            offstage: _catalogOpen,
            child: _ViewerBody(
            key: ValueKey('viewer-page-$_pageVersion'),
            modelUrl: _url,
            onJs: (js) {
              // Мост запоминаем, как только страница вьюера отдала API.
              if (js != null && mounted) setState(() => _js = js);
            },
            // Кнопка «Каталог» в шапке самого вьюера зовёт хендлер NexusApp
            // (п. C, замечания владельца 24.11) — открываем то же окошко.
            onOpenCatalog: () {
              if (!mounted) return;
              _openCatalog();
            },
          ),
          ),
        ),
      ),
      // Веб: тело — iframe переменного происхождения, наружной шапки у
      // страницы нет, поэтому «Каталог» — маленькая FAB внизу справа.
      // Она сидит у края и шапку вьюера (вверху) не перекрывает.
      floatingActionButton: kIsWeb
          ? FloatingActionButton.extended(
              onPressed: _openCatalog,
              icon: const Icon(Icons.grid_view_outlined),
              label: Text(tr('Каталог')),
            )
          : null,
    );
  }
}

/// Тело экрана: страница вьюера в ПОЛНОМ режиме — своя шапка видна
/// (владелец 24.11, п.1 возвращаем как было). При смене версии страницы
/// (модель не влезла в `load()` и открыли заново с `?url=`) родитель
/// меняет `key` — WebView пересоздаётся целиком.
class _ViewerBody extends StatelessWidget {
  final String? modelUrl;
  final void Function(StepViewerJs? js) onJs;
  final VoidCallback onOpenCatalog;

  const _ViewerBody({
    super.key,
    required this.modelUrl,
    required this.onJs,
    required this.onOpenCatalog,
  });

  @override
  Widget build(BuildContext context) {
    return impl.buildViewer(
      context,
      modelUrl: modelUrl,
      onJs: onJs,
      onOpenCatalog: onOpenCatalog,
    );
  }
}
