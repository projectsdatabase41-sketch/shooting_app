import 'package:flutter/widgets.dart';

/// Подсказка для шапок: «в этом поддереве можно переключать роль». Её ставит
/// `RoleSplit`; `GlassHeader` видит её и рисует справа круглую кнопку
/// «М» (мои) / «С» (спортсмены), симметрично кнопке «назад».
class RoleSwitchScope extends InheritedWidget {
  final bool coach;
  final VoidCallback toggle;
  const RoleSwitchScope({super.key, required this.coach, required this.toggle, required super.child});

  static RoleSwitchScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RoleSwitchScope>();

  @override
  bool updateShouldNotify(RoleSwitchScope old) => old.coach != coach;
}
