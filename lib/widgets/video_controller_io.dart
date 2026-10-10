import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'voice_bubble.dart' show MediaSource;

/// Контроллер воспроизведения видео из байтов (пишутся во временный файл) или файла.
Future<VideoPlayerController> videoControllerFor(MediaSource s) async {
  if (s.path != null) return VideoPlayerController.file(File(s.path!));
  final dir = await getTemporaryDirectory();
  final f = File(p.join(dir.path, 'circle_${s.bytes.hashCode}.mp4'));
  if (!await f.exists()) await f.writeAsBytes(s.bytes!);
  return VideoPlayerController.file(f);
}
