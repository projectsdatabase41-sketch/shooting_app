import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import 'coach_chat_view.dart';

/// «Чат с тренером» у спортсмена: переписка с тем, кому выдан токен
/// доступа (sql/coach-chat.sql). Тренеров несколько — выбор сверху.
/// Не мессенджер и не комментарии к тренировке — отдельный канал.
class AthleteCoachChat extends StatefulWidget {
  const AthleteCoachChat({super.key});

  @override
  State<AthleteCoachChat> createState() => _AthleteCoachChatState();
}

class _AthleteCoachChatState extends State<AthleteCoachChat> {
  late final SupabaseAuthService _auth = SupabaseAuthService(context.read<AppDataStore>().db);
  List<({String grantId, String name})>? _coaches;
  String? _error;
  String? _selected;

  @override
  void initState() {
    super.initState();
    if (_auth.isSignedIn) _load();
  }

  Future<void> _load() async {
    try {
      final list = await _auth.fetchChatCoaches();
      if (!mounted) return;
      setState(() {
        _coaches = list;
        _error = null;
        _selected ??= list.isEmpty ? null : list.first.grantId;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Widget _hint(String text) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center)),
      );

  @override
  Widget build(BuildContext context) {
    if (!_auth.isSignedIn) {
      return _hint('Чтобы переписываться с тренером, войдите в свою базу: Настройки → Учётная запись.');
    }
    final coaches = _coaches;
    if (coaches == null) {
      return _error == null ? const Center(child: CircularProgressIndicator()) : _hint(_error!);
    }
    if (coaches.isEmpty) {
      return _hint('Тренер ещё не подключён — выдайте ему токен доступа: Настройки → Данные и синхронизация.');
    }
    final current = coaches.firstWhere((c) => c.grantId == _selected, orElse: () => coaches.first);
    return Column(
      children: [
        if (coaches.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                for (final c in coaches)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c.name),
                      selected: c.grantId == current.grantId,
                      onSelected: (_) => setState(() => _selected = c.grantId),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: CoachChatView(
            key: ValueKey(current.grantId),
            myRole: 'athlete',
            otherLabel: current.name,
            load: () => _auth.fetchCoachChat(current.grantId),
            send: (text) => _auth.sendCoachChat(current.grantId, text),
            delete: _auth.deleteCoachChat,
          ),
        ),
      ],
    );
  }
}
