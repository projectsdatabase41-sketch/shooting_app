import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<bool> saveBytes(Uint8List bytes, String fileName) async {
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS));
  (web.document.createElement('a') as web.HTMLAnchorElement)
    ..href = url
    ..download = fileName
    ..click();
  web.URL.revokeObjectURL(url);
  return true;
}
