import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<bool> saveBytes(Uint8List bytes, String fileName) async =>
    await FilePicker.platform.saveFile(fileName: fileName, bytes: bytes) != null;
