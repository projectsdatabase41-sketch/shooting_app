import 'dart:js_interop';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'voice_bubble.dart' show MediaSource;

/// Веб: видео из байтов проигрывается через blob-адрес.
Future<VideoPlayerController> videoControllerFor(MediaSource s) async {
  final blob = web.Blob([s.bytes!.toJS].toJS, web.BlobPropertyBag(type: s.mime));
  return VideoPlayerController.networkUrl(Uri.parse(web.URL.createObjectURL(blob)));
}
