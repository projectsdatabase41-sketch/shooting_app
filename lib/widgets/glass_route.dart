import 'package:flutter/material.dart';

import '../theme/glass.dart';

/// `showDialog` с размытием фона за окном в режиме «стекло» (иначе — обычный диалог).
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      builder: (ctx) => GlassBlur(child: builder(ctx)),
    );

/// `showModalBottomSheet` с размытием за шторкой в режиме «стекло».
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = false,
  bool useSafeArea = false,
  bool enableDrag = true,
  bool isDismissible = true,
  bool useRootNavigator = false,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  Clip? clipBehavior,
  RouteSettings? routeSettings,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useRootNavigator: useRootNavigator,
      backgroundColor: backgroundColor,
      barrierColor: barrierColor,
      shape: shape,
      constraints: constraints,
      clipBehavior: clipBehavior,
      routeSettings: routeSettings,
      builder: (ctx) => GlassBlur(radius: 28, child: builder(ctx)),
    );
