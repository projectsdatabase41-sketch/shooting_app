import 'package:flutter/material.dart';

/// Фиксированный набор иконок для плиток сервисов (решение
/// пользователя: "Google Диск, Supabase, заметки и др.") — сама
/// `IconData` не сериализуется в базу, поэтому хранится ключ из этой
/// карты (`CustomService.iconName`), а не иконка напрямую.
const Map<String, IconData> serviceIcons = {
  'cloud': Icons.cloud_outlined,
  'storage': Icons.storage_outlined,
  'note': Icons.note_outlined,
  'link': Icons.link,
  'api': Icons.api_outlined,
  'dashboard': Icons.dashboard_outlined,
  'folder': Icons.folder_outlined,
  'code': Icons.code,
  'chat': Icons.chat_outlined,
  'analytics': Icons.query_stats_outlined,
  'calendar': Icons.calendar_month_outlined,
  'mail': Icons.mail_outline,
  'spreadsheet': Icons.table_chart_outlined,
  'document': Icons.description_outlined,
  'database': Icons.dns_outlined,
  'terminal': Icons.terminal,
  'video': Icons.videocam_outlined,
  'image': Icons.image_outlined,
  'music': Icons.music_note_outlined,
  'shopping': Icons.shopping_cart_outlined,
  'task': Icons.checklist_outlined,
  'globe': Icons.public,
  'lock': Icons.lock_outline,
  'star': Icons.star_outline,
  'bookmark': Icons.bookmark_outline,
  'settings': Icons.settings_outlined,
  'search': Icons.search,
  'bug': Icons.bug_report_outlined,
  'brain': Icons.psychology_outlined,
  'game': Icons.sports_esports_outlined,
  'finance': Icons.attach_money,
};

IconData iconForService(String name) => serviceIcons[name] ?? Icons.link;

class ServiceIconPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const ServiceIconPicker({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final entry in serviceIcons.entries)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onChanged(entry.key),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: entry.key == selected ? cs.primaryContainer : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: entry.key == selected ? Border.all(color: cs.primary, width: 2) : null,
              ),
              child: Icon(entry.value, color: entry.key == selected ? cs.onPrimaryContainer : cs.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
