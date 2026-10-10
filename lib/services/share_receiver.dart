import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_handler/share_handler.dart';

import '../screens/share_to_chat_screen.dart';
import 'local_db_service.dart';

/// Приём файлов из системного меню «Поделиться» (галерея, файлы): приложение
/// Nexus появляется в списке, а выбранные фото и файлы предлагаются к отправке
/// в чат мессенджера. Только Android.
class ShareReceiver {
  ShareReceiver._();

  static StreamSubscription<SharedMedia>? _sub;

  static void start(GlobalKey<NavigatorState> navigatorKey, LocalDbService db) {
    if (kIsWeb || _sub != null) return;
    try {
      final handler = ShareHandlerPlatform.instance;
      void handle(SharedMedia? media) {
        final files = <SharedFile>[
          for (final a in media?.attachments ?? const <SharedAttachment?>[])
            if (a != null) SharedFile(a.path, null),
        ];
        if (files.isEmpty) return;
        // Экран открываем после кадра: холодный старт — навигатор ещё строится.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigatorKey.currentState?.push(MaterialPageRoute(
            builder: (_) => ShareToChatScreen(db: db, files: files),
          ));
          handler.resetInitialSharedMedia();
        });
      }

      handler.getInitialSharedMedia().then(handle);
      _sub = handler.sharedMediaStream.listen(handle, onError: (_) {});
    } catch (_) {
      // платформа без поддержки — просто не принимаем
    }
  }
}
