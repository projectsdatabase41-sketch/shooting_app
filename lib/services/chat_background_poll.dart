import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'chat_auth_service.dart';
import 'chat_messages_repository.dart';
import 'chat_settings.dart';
import 'chat_sync_service.dart';
import 'local_db_service.dart';

/// Редкий опрос мессенджера, пока открыт экран приложения, но сам мессенджер
/// не открыт: красный кружок на значке мессенджера появляется и без захода в
/// него (новые сообщения и заявки в друзья). Раз в минуту, только на переднем
/// плане; когда мессенджер открыт, работает его собственный опрос.
class ChatBackgroundPoll {
  ChatBackgroundPoll(this.db, {required this.shouldPoll});

  final LocalDbService db;
  final bool Function() shouldPoll;
  Timer? _timer;
  bool _busy = false;

  Timer? _first;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => tick());
    _first = Timer(const Duration(seconds: 5), tick);
  }

  void stop() {
    _timer?.cancel();
    _first?.cancel();
    _timer = null;
    _first = null;
  }

  Future<void> tick() async {
    if (_busy || !shouldPoll()) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    if (!ChatSettings.isConfigured) return;
    final auth = ChatAuthService(db);
    if (!auth.isSignedIn) return;
    _busy = true;
    try {
      await ChatSyncService(auth, ChatMessagesRepository(db)).pollIncoming();
      final requests = await auth.fetchFriendRequests();
      ChatAuthService.pendingFriends.value = requests.length;
    } catch (_) {
      // сеть — в следующий раз
    } finally {
      _busy = false;
    }
  }
}
