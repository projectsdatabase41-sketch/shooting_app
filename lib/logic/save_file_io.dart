import '../services/app_lock.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<bool> saveBytes(Uint8List bytes, String fileName) async =>
    await AppLock.external(() => FilePicker.platform.saveFile(fileName: fileName, bytes: bytes)) != null;
