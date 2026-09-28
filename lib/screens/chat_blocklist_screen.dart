import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
import '../widgets/chat_avatar.dart';
import '../widgets/empty_state.dart';

/// Чёрный список: от этих людей сообщения не доходят (сервер молча их
/// отбрасывает), в друзья они не попадают. «Разблокировать» — убрать из списка.
class ChatBlocklistScreen extends StatefulWidget {
  final ChatAuthService auth;
  const ChatBlocklistScreen({super.key, required this.auth});

  @override
  State<ChatBlocklistScreen> createState() => _ChatBlocklistScreenState();
}

class _ChatBlocklistScreenState extends State<ChatBlocklistScreen> {
  List<({String userId, String nickname, String? avatarBase64})>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.auth.myBlocks();
      if (mounted) setState(() => (_list = l, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _unblock(String id) async {
    try {
      await widget.auth.unblockUser(id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Чёрный список'))),
      body: list == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : list.isEmpty
              ? EmptyState(icon: Icons.block, text: tr('Чёрный список пуст'))
              : ListView(
                  children: [
                    for (final b in list)
                      ListTile(
                        leading: ChatAvatar(base64: b.avatarBase64, nickname: b.nickname),
                        title: Text(b.nickname),
                        trailing: TextButton(onPressed: () => _unblock(b.userId), child: Text(tr('Разблокировать'))),
                      ),
                  ],
                ),
    );
  }
}
