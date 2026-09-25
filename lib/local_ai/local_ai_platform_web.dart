// ponytail: в браузере llama.cpp работает только через экспериментальный
// WebGPU — пока выключено; включить здесь, когда проверим.
const bool localAiSupported = false;

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

Future<String> modelsDir() async => throw UnsupportedError('web');
Future<int?> totalRamBytes() async => null;
Future<int?> freeDiskBytes(String dir) async => null;
int fileLength(String path) => 0;
Future<void> deleteFile(String path) async {}
Future<String> sha256OfFile(String path) async => throw UnsupportedError('web');
Future<void> downloadResumable(
  Uri url,
  String path, {
  required void Function(int got, int total) onProgress,
  required bool Function() cancelled,
}) async =>
    throw UnsupportedError('web');
