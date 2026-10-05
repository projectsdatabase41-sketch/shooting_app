import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Как сейчас идут сообщения этой переписки:
/// SB — через базу Supabase (записываются и читаются по опросу);
/// RT — Realtime: живой канал через сервер, в базу не пишутся;
/// P2P — прямое соединение WebRTC между устройствами, сервер не видит текст.
enum LinkMode { sb, rt, p2p }

LinkMode linkMode({required bool direct, required bool live}) => direct
    ? LinkMode.p2p
    : live
        ? LinkMode.rt
        : LinkMode.sb;

extension LinkModeInfo on LinkMode {
  String get label => switch (this) {
        LinkMode.sb => 'SB',
        LinkMode.rt => 'RT',
        LinkMode.p2p => 'P2P'
      };

  Color get color => switch (this) {
        LinkMode.sb => const Color(0xFFFFB300),
        LinkMode.rt => const Color(0xFF8BC34A),
        LinkMode.p2p => const Color(0xFF3DDC84),
      };

  IconData get icon => switch (this) {
        LinkMode.sb => Icons.storage_outlined,
        LinkMode.rt => Icons.bolt,
        LinkMode.p2p => Icons.verified_user_outlined,
      };

  String get title => switch (this) {
        LinkMode.sb => tr('SB — через базу Supabase'),
        LinkMode.rt => tr('RT — Realtime через сервер'),
        LinkMode.p2p => tr('P2P — напрямую между устройствами'),
      };

  String get description => switch (this) {
        LinkMode.sb => tr(
            'Сообщение записывается в базу, собеседник забирает его по опросу раз в несколько секунд и оно удаляется с сервера. Работает всегда, в том числе если собеседник не в сети. Самый медленный путь, текст на время лежит в базе.'),
        LinkMode.rt => tr(
            'Оба в переписке: сообщение летит через сервер мгновенно и в базу не записывается. Если собеседник не подтвердил за пару секунд — уходит через базу (SB).'),
        LinkMode.p2p => tr(
            'Устройства соединились напрямую (WebRTC): текст не проходит через сервер вообще. Самый быстрый и приватный путь.'),
      };
}

/// Значок «как идёт связь» в шапке переписки: сокращение + щит/молния/база,
/// по нажатию — пояснение всех трёх путей.
class LinkSignal extends StatelessWidget {
  final LinkMode mode;
  const LinkSignal({super.key, required this.mode});

  static void explain(BuildContext context, LinkMode current) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Как идут сообщения')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final m in LinkMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(m.icon, color: m.color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m == current
                                  ? '${m.title} · ${tr('сейчас')}'
                                  : m.title,
                              style: TextStyle(
                                  fontWeight: m == current
                                      ? FontWeight.w700
                                      : FontWeight.w500),
                            ),
                            const SizedBox(height: 2),
                            Text(m.description,
                                style: Theme.of(ctx).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr('Закрыть')))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = mode.color;
    return GestureDetector(
      onTap: () => explain(context, mode),
      child: Tooltip(
        message: mode.title,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            border: Border.all(color: color.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon, size: 13, color: color),
              const SizedBox(width: 3),
              Text(mode.label,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
