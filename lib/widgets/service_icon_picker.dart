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
