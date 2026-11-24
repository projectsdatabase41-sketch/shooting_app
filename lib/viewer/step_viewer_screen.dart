import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';
import 'models_catalog_screen.dart'
    show ModelsCatalog, ModelsCatalogBody;
import 'step_viewer_common.dart';
import 'step_viewer_io.dart'
    if (dart.library.html) 'step_viewer_web.dart' as impl;

/// Просмотр 3D-моделей (STEP/GLB) — ЕДИНЫЙ экран вместо двух страниц
/// («вьюер» + «каталог», просьба владельца 24.11):
///
/// - вверху одна строка кнопок в стеклянных «таблетках»: «Каталог» и
///   «Открыть STEP» всегда первыми слева, за ними «Рёбра», «Свойства»,
///   «Отображение» (при нехватке ширины строка горизонтально скроллится);
/// - тело — вьюер в режиме `?embed=1` (собственная шапка вьюера спрятана,
///   поддержка есть в assets/webview);
/// - «Каталог» открывает окошко почти на весь экран с сеткой превью
///   (`ModelsCatalogBody`); выбор модели грузится в уже открытый вьюер
///   через `NexusViewer.load(url)`, без пересоздания экрана.
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
  String? _url;

  /// Мост к `window.NexusViewer`. Появляется, когда страница вьюера
  /// догрузилась и отдала публичный API (Android); на вебе мостов нет —
  /// кнопки «Рёбра/Свойства/Отображение» там скрываются (требование A,
  /// владелец 24.11: только на Android есть evaluateJavascript).
  StepViewerJs? _js;

  /// Сколько раз страница вьюера пересоздавалась. Нужен только как ключ
  /// тела: WebView нельзя перенаправить снаружи, поэтому проще, чтобы
  /// страница открылась заново с параметром `?url=`.
  int _pageVersion = 0;

  /// «Рёбра»: включены по умолчанию — это и начальное состояние вьюера
  /// (assets/webview/app.js: edgesEnabled: true). Спросить вьюер снаружи
  /// нельзя, поэтому состояние кнопки храним здесь (требование A, п.3).
  bool _edgesOn = true;

  @override
  void initState() {
    super.initState();
    _url = widget.modelUrl; // открытие по modelUrl извне не ломаем
  }

  bool get _hasBridge =>
      !kIsWeb; // мост есть только на Android (WebView-контроллер)

  /// Загрузить модель: выбор из каталога (и «Открыть по ссылке») НЕ
  /// пересоздаёт экран — сначала пробуем `NexusViewer.load(url)` в уже
  /// открытом вьюере; не готов — открываем страницу заново с `?url=`
  /// (требование B, владелец 24.11).
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
    final cs = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      barrierColor: Theme.of(context).brightness == Brightness.dark
          ? Colors.black54
          : Colors.black26,
      builder: (ctx) => Dialog(
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
                  onPick: (id) {
                    Navigator.of(ctx).pop(); // закрыть окошко
                    _loadModel(ModelsCatalog.modelUrl(id));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Кнопки верхней панели --------------------------------------------

  /// «Открыть STEP»: файл с устройства.
  /// Android — через `NexusViewer.openFile()` (тот же клик по скрытому
  /// input, что и у кнопки вьюера; владелец 24.11). На вебе из Flutter в
  /// iframe системный выбор файла не открыть, поэтому показываем вьюер в
  /// полном режиме — там своя шапка с «Открыть STEP» (требование A, п.2).
  Future<void> _openFile() async {
    if (_hasBridge) {
      try {
        await _js?.invoke('openFile', const []);
      } catch (_) {
        // Мост ещё не готов — ничего не делаем: вьюер рисует прогресс,
        // а повторный тап по кнопке сработает, как только страница готова.
      }
      return;
    }
    // Веб (и всё без моста): страница вьюера со своей шапкой.
    if (mounted) _showFullViewerSheet();
  }

  /// Вьюер в полном режиме со своей шапкой (в ней «Открыть STEP» и
  /// «Открыть по ссылке») в окошке почти на весь экран; над iframe —
  /// наша тонкая строка с кнопкой возврата: из Flutter наружные элементы
  /// iframe не дотянуть, закрыть так надёжнее.
  void _showFullViewerSheet() {
    final cs = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      barrierColor: Theme.of(context).brightness == Brightness.dark
          ? Colors.black54
          : Colors.black26,
      builder: (ctx) => Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: cs.outlineVariant),
        ),
        // Те же габариты, что и у окошка каталога (владелец 24.11).
        insetPadding: EdgeInsets.symmetric(
          vertical: MediaQuery.sizeOf(ctx).height * 0.04,
          horizontal: MediaQuery.sizeOf(ctx).width * 0.02,
        ),
        child: SizedBox(
          width: MediaQuery.sizeOf(ctx).width * 0.96,
          height: MediaQuery.sizeOf(ctx).height * 0.92,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(
                    children: [
                      GlassCircleButton(
                        tooltip: tr('Назад'),
                        icon: const Icon(Icons.close),
                        onTap: () => Navigator.of(ctx).pop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr('Полный режим вьюера'),
                          style: Theme.of(ctx).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  // Модель, уже открытая на экране, передаётся: страница
                  // заново стартует с `?url=` (моста на вебе нет).
                  child: impl.buildViewer(
                    ctx,
                    modelUrl: _url,
                    embed: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop == true;

    return Scaffold(
      // Клавиатура не должна сжимать WebView: при каждом кадре открытия она
      // пересчитывала размер и перерисовывала 3D-сцену (отзыв 16.11).
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      // Шапка нового образца (владелец 24.11): не панель с заголовком, а
      // строка стеклянных кнопок в одном стиле, при нехватке ширины —
      // со скроллом вбок.
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(GlassHeader.height),
        child: _Toolbar(
          canPop: canPop,
          edgeSelected: _edgesOn,
          showBridgeButtons: _hasBridge,
          onCatalog: _openCatalog,
          onOpenFile: _openFile,
          onEdges: _toggleEdges,
          onMass: () => _js?.openMass(),
          onDisplay: () => _js?.openDisplay(),
        ),
      ),
      body: AppBackdrop(
        kind: 'settings',
        child: _ViewerBody(
          key: ValueKey('viewer-page-$_pageVersion'),
          modelUrl: _url,
          onJs: (js) {
            // Мост запоминаем, как только страница вьюера отдала API.
            if (js != null && mounted) setState(() => _js = js);
          },
        ),
      ),
    );
  }

  void _toggleEdges() {
    final on = !_edgesOn; // состояние кнопки живёт здесь (владелец 24.11)
    setState(() => _edgesOn = on);
    _js?.setEdges(on);
  }
}

/// Строка кнопок шапки: стеклянные «таблетки» с иконкой и подписью, как в
/// остальных шапках приложения (`GlassPill`). «Каталог» и «Открыть STEP»
/// всегда первыми слева; «Рёбра», «Свойства», «Отображение» — после них
/// и только там, где есть JS-мост (владелец 24.11).
class _Toolbar extends StatelessWidget implements PreferredSizeWidget {
  final bool canPop;
  final bool edgeSelected;
  final bool showBridgeButtons;
  final VoidCallback onCatalog;
  final VoidCallback onOpenFile;
  final VoidCallback onEdges;
  final VoidCallback onMass;
  final VoidCallback onDisplay;

  const _Toolbar({
    required this.canPop,
    required this.edgeSelected,
    required this.showBridgeButtons,
    required this.onCatalog,
    required this.onOpenFile,
    required this.onEdges,
    required this.onMass,
    required this.onDisplay,
  });

  @override
  Size get preferredSize => const Size.fromHeight(GlassHeader.height);

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, safe + 6, 0, 6),
      child: Row(
        children: [
          if (canPop) ...[
            const SizedBox(width: 8),
            GlassCircleButton(
              tooltip: tr('Назад'),
              icon: const BoldIcon(Icons.arrow_back),
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  _ToolPill(
                    icon: Icons.grid_view_outlined,
                    label: tr('Каталог'),
                    onTap: onCatalog,
                  ),
                  _ToolPill(
                    icon: Icons.folder_open_outlined,
                    label: tr('Открыть STEP'),
                    onTap: onOpenFile,
                  ),
                  if (showBridgeButtons) ...[
                    _ToolPill(
                      icon: Icons.polyline_outlined,
                      label: tr('Рёбра'),
                      selected: edgeSelected,
                      onTap: onEdges,
                    ),
                    _ToolPill(
                      icon: Icons.fact_check_outlined,
                      label: tr('Свойства'),
                      onTap: onMass,
                    ),
                    _ToolPill(
                      icon: Icons.contrast,
                      label: tr('Отображение'),
                      onTap: onDisplay,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Компактная кнопка в стеклянном стиле: иконка + подпись. Выбранное
/// состояние (например, «Рёбра» включены) подсвечиваем цветом темы —
/// так же, как выбранные чипы.
class _ToolPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  const _ToolPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GlassPill(
        // Выбранная кнопка — с подложкой цвета темы (владелец 24.11:
        // состояние «Рёбра» должно читаться глазами).
        color: selected ? cs.primary.withValues(alpha: 0.25) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: cs.onSurface),
            const SizedBox(width: 6),
            Text(label, style: labelStyle),
          ],
        ),
      ),
    );
  }
}

/// Тело экрана: страница вьюера в embed-режиме. При смене версии страницы
/// (модель не влезла в `load()` и открыли заново с `?url=`) родитель меняет
/// `key` — WebView пересоздаётся целиком.
class _ViewerBody extends StatelessWidget {
  final String? modelUrl;
  final void Function(StepViewerJs? js) onJs;

  const _ViewerBody({
    super.key,
    required this.modelUrl,
    required this.onJs,
  });

  @override
  Widget build(BuildContext context) {
    return impl.buildViewer(
      context,
      modelUrl: modelUrl,
      embed: true,
      onJs: onJs,
    );
  }
}
