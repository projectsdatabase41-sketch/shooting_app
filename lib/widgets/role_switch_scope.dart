import 'package:flutter/widgets.dart';

/// Подсказка для шапок: «в этом поддереве можно переключать роль». Её ставит
/// `RoleSplit`; `GlassHeader` видит её и рисует справа круглую кнопку
/// «М» (мои) / «С» (спортсмены), симметрично кнопке «назад»; по нажатию
/// выпадает список из двух строк, выбор закрывает его.
class RoleSwitchScope extends InheritedWidget {
  final bool coach;
  final ValueChanged<bool> select; // true — «Спортсмены», false — «Мои»
  const RoleSwitchScope({super.key, required this.coach, required this.select, required super.child});

  static RoleSwitchScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RoleSwitchScope>();

  @override
  bool updateShouldNotify(RoleSwitchScope old) => old.coach != coach;
}
