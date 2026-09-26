import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'chat_auth_service.dart';
import 'chat_settings.dart';
import '../i18n/i18n.dart';

/// Большие вложения чата (свыше `ChatMediaUtils.maxAttachmentBytes`) —
/// идут не через Supabase Storage (там лимит 50 МБ), а напрямую в
/// Google Drive: этот сервис лишь получает короткоживущий токен через
/// Edge Function `chat-drive-token` (см. supabase/functions/chat-drive-token
/// и google-apps-script/chat-drive-relay.gs), а сами байты файла идут
/// НАПРЯМУЮ между устройством и googleapis.com — ни Supabase, ни Apps
/// Script их не видят и не проксируют.
///
/// Недоступно на вебе (`kIsWeb`) — нужен путь к файлу на диске для
/// потокового чтения/записи без загрузки гигабайт в память; вызывающий
/// код (`ChatSyncService`) это не проверяет сам, значит webе такие
/// сообщения просто не отправляются (пункт для UI — скрыть там кнопку).
class ChatDriveService {
  final ChatAuthService auth;
  final http.Client Function() clientFactory;

  ChatDriveService(this.auth, {http.Client Function()? clientFactory}) : clientFactory = clientFactory ?? http.Client.new;

  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _transferTimeout = Duration(minutes: 60);

  Future<Map<String, dynamic>> _callFunction(Map<String, dynamic> body) async {
    final token = await auth.ensureFreshToken();
    if (token == null) throw Exception(tr('Сначала войдите в чат'));
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${ChatSettings.url}/functions/v1/chat-drive-token'),
            headers: {
              'apikey': ChatSettings.anonKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode >= 300) {
        throw Exception('${json['error'] ?? res.body}');
      }
      return json;
    } finally {
      client.close();
    }
  }

  /// Токен + папка — действуют около часа, берём заново перед каждой
  /// передачей (загрузка/скачивание), а не кешируем в приложении: сама
  /// передача может занять минуты, а токен всё равно живёт с запасом.
  Future<(String token, String folderId)> _getUploadToken() async {
    final json = await _callFunction({'action': 'getUploadToken'});
    final token = json['token'] as String?;
    final folderId = json['folderId'] as String?;
    if (token == null || folderId == null) throw Exception(tr('Диск не выдал токен: {json}', {'json': json}));
    return (token, folderId);
  }

  /// Стирает файл с Диска — самоочистка после подтверждённого скачивания
  /// получателем (см. `ChatSyncService.downloadLargeAttachment`).
  /// Best-effort: осиротевший файл на выделенном Диске — не авария,
  /// можно почистить вручную позже (тот же принцип, что у
  /// `ChatSyncService._deleteAttachment`).
  Future<void> deleteFile(String fileId) async {
    try {
      await _callFunction({'action': 'delete', 'fileId': fileId});
    } catch (_) {
      // необязательно
    }
  }

  /// Загружает файл по [filePath] целиком одним потоковым PUT в
  /// resumable-сессию Google Drive — без буферизации байт целиком в
  /// памяти приложения (`file.openRead()` читает с диска по кускам,
  /// сколько отправляет `http`). Возвращает id файла на Диске.
  Future<String> upload({
    required String filePath,
    required String fileName,
    required String mime,
  }) async {
    final (accessToken, folderId) = await _getUploadToken();
    final file = File(filePath);
    final length = await file.length();
    final client = clientFactory();
    try {
      final initRes = await client
          .post(
            Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json; charset=UTF-8',
              'X-Upload-Content-Type': mime,
              'X-Upload-Content-Length': '$length',
            },
            body: jsonEncode({
              'name': fileName,
              'parents': [folderId],
            }),
          )
          .timeout(_timeout);
      final sessionUri = initRes.headers['location'];
      if (initRes.statusCode >= 300 || sessionUri == null) {
        throw Exception(tr('Не удалось начать загрузку на Диск ({statusCode}): {body}', {'statusCode': initRes.statusCode, 'body': initRes.body}));
      }

      final request = http.StreamedRequest('PUT', Uri.parse(sessionUri))
        ..headers['Content-Length'] = '$length'
        ..headers['Content-Type'] = mime;
      unawaited(file.openRead().forEach(request.sink.add).then((_) => request.sink.close(), onError: request.sink.addError));

      final streamedRes = await client.send(request).timeout(_transferTimeout);
      final body = await streamedRes.stream.bytesToString();
      if (streamedRes.statusCode >= 300) {
        throw Exception(tr('Не удалось загрузить файл на Диск ({statusCode}): {body}', {'statusCode': streamedRes.statusCode, 'body': body}));
      }
      final fileId = (jsonDecode(body) as Map<String, dynamic>)['id'] as String?;
      if (fileId == null) throw Exception(tr('Диск не вернул id файла: {body}', {'body': body}));
      return fileId;
    } finally {
      client.close();
    }
  }

  /// Скачивает файл [fileId] потоково в [destPath] — пишет на диск по
  /// мере получения, не копит гигабайты в памяти. [onProgress] — сколько
  /// байт уже получено (второй параметр — общий размер, если известен).
  Future<void> download({
    required String fileId,
    required String destPath,
    void Function(int received, int? total)? onProgress,
  }) async {
    final (accessToken, _) = await _getUploadToken();
    final client = clientFactory();
    try {
      final request = http.Request('GET', Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'))
        ..headers['Authorization'] = 'Bearer $accessToken';
      final streamedRes = await client.send(request).timeout(_transferTimeout);
      if (streamedRes.statusCode >= 300) {
        final body = await streamedRes.stream.bytesToString();
        throw Exception(tr('Не удалось скачать файл ({statusCode}): {body}', {'statusCode': streamedRes.statusCode, 'body': body}));
      }
      final sink = File(destPath).openWrite();
      var received = 0;
      final total = streamedRes.contentLength;
      try {
        await streamedRes.stream.forEach((chunk) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        });
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }
}
