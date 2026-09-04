import 'package:flutter/material.dart';

/// Единая визуальная тема приложения — светлая и тёмная.
///
/// Появилась по запросу пользователя ("хорошо бы стили добавить, а то
/// как-то очень просто"): раньше на всё приложение был один
/// `ThemeData(colorSchemeSeed: Color(0xFF37474F))`, из-за чего экраны
/// выглядели как голая заготовка Material.
///
/// **Не путать с персонализацией цвета мишени.** Цвета самой мишени
/// (бумага, яблоко, кольца, пробоины) живут в `TargetColorScheme` /
/// `PersonalizationViewModel` и настраиваются пользователем отдельно
/// (часть A логики-спека, раздел 9 ТЗ). Здесь — только цвета интерфейса
/// вокруг мишени. Связывать их намеренно НЕ надо: стрелок подбирает
/// цвета мишени под свою видимость, а не под тему приложения.
///
/// Палитра: графитово-синий (спокойный "технический" цвет приборов и
/// оружейной стали) как основной + янтарный акцент для результатов и
/// активных состояний. Янтарь выбран не случайно — это же семейство,
/// что и золотой цвет выбранной пробоины на мишени, так что акцент
/// интерфейса и акцент мишени читаются как одна система.
///
/// **О совместимости с версиями Flutter.** Подтемы, которые в новых
/// версиях Flutter переименованы из `XTheme` в `XThemeData`
/// (`cardTheme`, `appBarTheme`, `dialogTheme`, `inputDecorationTheme`),
/// здесь НЕ конструируются напрямую по имени класса, а получаются через
/// `base.<подтема>.copyWith(...)`. `copyWith` возвращает тот же тип,
/// который ожидает `ThemeData` этой конкретной версии SDK, поэтому файл
/// собирается и до, и после переименования. Проект сейчас на Dart 3.11 /
/// Flutter 3.38, но правило дешёвое и стоит того.
class AppTheme {
  const AppTheme._();

  /// Радиус скругления карточек и крупных поверхностей.
  static const double radiusLarge = 16;

  /// Радиус кнопок, полей ввода, чипов.
  static const double radiusMedium = 12;

  static const Color _slate = Color(0xFF2C4A63);
  static const Color _amber = Color(0xFFC98A15);

  static ThemeData light() => _build(_scheme(Brightness.light));

  static ThemeData dark() => _build(_scheme(Brightness.dark));

  static ColorScheme _scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(seedColor: _slate, brightness: brightness);
    if (brightness == Brightness.light) {
      return base.copyWith(
        primary: _slate,
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFD6E4F2),
        onPrimaryContainer: const Color(0xFF11283C),
        // Янтарь на светлом фоне берём затемнённый — светлый янтарь на
        // белом не проходит по контрасту для текста.
        secondary: const Color(0xFF8A5D0B),
        onSecondary: const Color(0xFFFFFFFF),
        secondaryContainer: const Color(0xFFFBE6BC),
        onSecondaryContainer: const Color(0xFF2C1D00),
        tertiary: const Color(0xFF4B6650),
        onTertiary: const Color(0xFFFFFFFF),
        surface: const Color(0xFFF6F8FA),
        onSurface: const Color(0xFF161B20),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFF1F4F7),
        surfaceContainer: const Color(0xFFEBEFF4),
        surfaceContainerHigh: const Color(0xFFE4EAF0),
        surfaceContainerHighest: const Color(0xFFDDE4EB),
        onSurfaceVariant: const Color(0xFF525C66),
        outline: const Color(0xFF8994A0),
        outlineVariant: const Color(0xFFD2DAE2),
        error: const Color(0xFFB3261E),
        onError: const Color(0xFFFFFFFF),
      );
    }
    return base.copyWith(
      primary: const Color(0xFF9CC5E8),
      onPrimary: const Color(0xFF0A2437),
      primaryContainer: const Color(0xFF23405A),
      onPrimaryContainer: const Color(0xFFD6E4F2),
      secondary: _amberLight,
      onSecondary: const Color(0xFF2C1D00),
      secondaryContainer: const Color(0xFF503A06),
      onSecondaryContainer: const Color(0xFFFBE6BC),
      tertiary: const Color(0xFFAFCBB3),
      onTertiary: const Color(0xFF1B3421),
      surface: const Color(0xFF11161B),
      onSurface: const Color(0xFFE1E7ED),
      surfaceContainerLowest: const Color(0xFF0B0F13),
      surfaceContainerLow: const Color(0xFF161C22),
      surfaceContainer: const Color(0xFF1B222A),
      surfaceContainerHigh: const Color(0xFF232C35),
      surfaceContainerHighest: const Color(0xFF2C3640),
      onSurfaceVariant: const Color(0xFFA7B2BD),
      outline: const Color(0xFF6A747F),
      outlineVariant: const Color(0xFF39424C),
      error: const Color(0xFFF2B8B5),
      onError: const Color(0xFF601410),
    );
  }

  static const Color _amberLight = Color(0xFFE5BE68);

  /// Акцентный янтарь для крупных числовых показателей — на светлой теме
  /// затемнённый (иначе не читается), на тёмной осветлённый.
  static Color accentFor(ColorScheme cs) =>
      cs.brightness == Brightness.light ? _amber : _amberLight;

  static ThemeData _build(ColorScheme cs) {
    final base = ThemeData(colorScheme: cs);
    final t = base.textTheme;

    // Табличные цифры — чтобы результаты (10.9 / 9.4 / 109.0) не
    // "прыгали" по ширине при обновлении и колонки чисел выравнивались.
    const tabular = [FontFeature.tabularFigures()];

    final textTheme = t.copyWith(
      displaySmall: t.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        fontFeatures: tabular,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        fontFeatures: tabular,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        fontFeatures: tabular,
      ),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
      labelSmall: t.labelSmall?.copyWith(letterSpacing: 0.4),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.35),
      bodySmall: t.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.3),
    );

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: cs.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,

      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(fontSize: 20, color: cs.onSurface),
        // Тонкая линия под шапкой вместо тени — тень на плоской теме
        // выглядит грязно, а граница нужна, иначе шапка сливается со
        // списком под ней.
        shape: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),

      cardTheme: base.cardTheme.copyWith(
        // В светлой теме карточка светлее фона (белая на сером), в
        // тёмной — наоборот, чуть светлее почти чёрного фона. Один и тот
        // же токен для обеих тем дал бы в тёмной карточку ТЕМНЕЕ фона,
        // то есть провал вместо приподнятости.
        color: cs.brightness == Brightness.light
            ? cs.surfaceContainerLowest
            : cs.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),

      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: cs.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge + 4)),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: cs.onSurface),
      ),

      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: cs.surfaceContainerLow,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: cs.primary, width: 1.6),
        ),
        labelStyle: TextStyle(color: cs.onSurfaceVariant),
      ),

      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: cs.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: cs.primaryContainer,
        indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? cs.onSurface : cs.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          );
        }),
      ),

      filledButtonTheme: FilledButtonThemeData(style: _buttonStyle()),
      elevatedButtonTheme: ElevatedButtonThemeData(style: _buttonStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _buttonStyle().copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: cs.outline)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        elevation: 2,
        highlightElevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusLarge)),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        titleTextStyle: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: textTheme.bodySmall,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
      ),

      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      chipTheme: base.chipTheme.copyWith(
        backgroundColor: cs.surfaceContainer,
        side: BorderSide(color: cs.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
        labelStyle: textTheme.labelLarge,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: cs.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
      ),

      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: cs.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge + 4)),
        ),
      ),

      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: cs.primary,
        inactiveTrackColor: cs.surfaceContainerHighest,
        thumbColor: cs.primary,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: cs.primary,
        linearTrackColor: cs.surfaceContainerHighest,
      ),
    );
  }

  static ButtonStyle _buttonStyle() => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMedium)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.1),
        ),
      );
}
