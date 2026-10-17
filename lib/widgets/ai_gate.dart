import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/modules_settings.dart';
import '../state/app_data_store.dart';

/// Включён ли модуль «Ассистент ИИ». Выключен — все кнопки и блоки с ИИ скрыты
/// (везде, где они есть), остаётся ручной режим.
bool aiModuleOn(BuildContext context) =>
    ModulesSettings.isOn(context.read<AppDataStore>().db, AppModule.assistant);
