import 'package:flutter/material.dart';

import '../services/custom_services_repository.dart';
import '../widgets/empty_state.dart';
import '../widgets/service_icon_picker.dart';
import 'add_service_screen.dart';
import '../i18n/i18n.dart';

/// "Сервисы" (решение пользователя) — сторонние сервисы (Google Диск,
/// Supabase, заметки и др.), которые пользователь сам подключает и
/// которые затем появляются плиткой на главном экране (см.
/// `HomeShell` — id вкладки `service_<id>`).
class SettingsServicesScreen extends StatelessWidget {
  final CustomServicesRepository repo;
  const SettingsServicesScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repo,
      builder: (context, _) {
        final services = repo.list();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Сервисы'))),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AddServiceScreen(repo: repo)),
            ),
            icon: const Icon(Icons.add),
            label: Text(tr('Сервис')),
          ),
          body: services.isEmpty
              ? EmptyState(
                  icon: Icons.dashboard_customize_outlined,
                  text: tr('Сервисов пока нет — подключите Google Диск, Supabase, заметки или что-то ещё, и на главном экране появится своя плитка.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: services.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = services[i];
                    return Card(
                      child: ListTile(
                        leading: Icon(iconForService(s.iconName)),
                        title: Text(s.name),
                        subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => AddServiceScreen(repo: repo, existing: s)),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmDelete(context, s.id, s.name),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, String id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Удалить сервис?')),
        content: Text(tr('«{name}» пропадёт из настроек и с главного экрана.', {'name': name})),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () {
              repo.delete(id);
              Navigator.of(ctx).pop();
            },
            child: Text(tr('Удалить')),
          ),
        ],
      ),
    );
  }
}
