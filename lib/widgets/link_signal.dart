import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
import 'glass_route.dart';

/// Как сейчас идут сообщения этой переписки:
/// SB — через базу сервера мессенджера (записываются и читаются по опросу);
/// RT — Realtime: живой канал через сервер, в базу не пишутся;
/// P2P — прямое соединение WebRTC между устройствами, сервер не видит текст.
enum LinkMode { sb, rt, p2p }

LinkMode linkMode({required bool direct, required bool live}) => direct
    ? LinkMode.p2p
    : live
        ? LinkMode.rt
        : LinkMode.sb;

extension LinkModeInfo on LinkMode {
  /// Техническое сокращение; по умолчанию в интерфейсе не показывается
  /// (спрятано за режим разработчика, отзыв владельца 22.11, 19:13).
  String get label => switch (this) {
        LinkMode.sb => 'SB',
        LinkMode.rt => 'RT',
        LinkMode.p2p => 'P2P'
      };

  /// Старый фиксированный цвет (вариант для тёмной темы). Оставлен для
  /// совместимости: на светлой теме эти оттенки не читаются на белом,
  /// поэтому в интерфейсе цвет берётся через [colorOn].
  Color get color => switch (this) {
        LinkMode.sb => const Color(0xFFFFB300),
        LinkMode.rt => const Color(0xFF8BC34A),
        LinkMode.p2p => const Color(0xFF3DDC84),
      };

  /// Цвет щита под текущую тему (отзыв владельца 22.11, 19:13): серый — в сети
  /// и работает SB (низкий уровень шифрования), жёлтый — RT (средний),
  /// зелёный — P2P (максимальный). В светлой теме жёлтый и зелёный берём
  /// затемнённые из схемы: светлый янтарь/салатовый на белом не читается.
  Color colorOn(ColorScheme cs) => switch (this) {
        LinkMode.sb => cs.onSurfaceVariant,
        LinkMode.rt => cs.secondary,
        LinkMode.p2p => cs.brightness == Brightness.dark
            ? const Color(0xFF3DDC84)
            : cs.tertiary,
      };

  IconData get icon => switch (this) {
        LinkMode.sb => Icons.storage_outlined,
        LinkMode.rt => Icons.bolt,
        LinkMode.p2p => Icons.verified_user_outlined,
      };

  String get title => switch (this) {
        LinkMode.sb => tr('SB — нет связи с собеседником'),
        LinkMode.rt => tr('RT — через сервер мессенджера'),
        LinkMode.p2p => tr('P2P — напрямую с собеседником'),
      };

  String get description => switch (this) {
        LinkMode.sb => tr(
            'Сообщения хранятся в базе мессенджера, пока собеседник их не прочитает. Работает, если собеседник не в сети и другие способы связи недоступны.'),
        LinkMode.rt => tr(
            'Соединение с собеседником через сервер мессенджера. Включается, если прямое соединение (P2P) недоступно.'),
        LinkMode.p2p => tr(
            'Соединение напрямую с собеседником. Подключается автоматически.'),
      };

  /// Уровень шифрования простыми словами (отзыв владельца 22.11, 19:13:
  /// «объяснения написать коротко, уровень шифрования, низкий, средний
  /// и максимальный»). Ровно эти три слова — для tooltip и диалога.
  String get encryptionLevel => switch (this) {
        LinkMode.sb => tr('низкий'),
        LinkMode.rt => tr('средний'),
        LinkMode.p2p => tr('максимальный'),
      };

  /// Одна строка пояснения к уровню: что именно значит на практике.
  String get encryptionNote => switch (this) {
        LinkMode.sb => tr(
            'Сообщение лежит в базе сервера, пока собеседник его не заберёт.'),
        LinkMode.rt => tr(
            'Сервер видит текст в момент доставки, но не хранит его в базе.'),
        LinkMode.p2p => tr(
            'Сообщение идёт напрямую между устройствами, сервер не видит текст.'),
      };
}

/// Значок связи в шапке переписки: щит с буквой «N» внутри. Цвет щита —
/// уровень шифрования, подпись вместо него не нужна обычному пользователю.
/// Так задумано по отзыву владельца 22.11, 19:13: «стоит сделать символом
/// щита где сейчас SB и другие… а то как сейчас спрятать за режим разработчика».
class LinkSignal extends StatelessWidget {
  final LinkMode mode;
  const LinkSignal({super.key, required this.mode});

  /// Размер щита: в шапке чата рядом с именем собеседника, крупнее не влезает.
  static const double _shieldSize = 18;

  static void explain(BuildContext context, LinkMode current) {
    showGlassDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(tr('Защита сообщений')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Сначала расшифровка значка — иначе щит в шапке непонятен.
                Text(
                  tr('Щит с буквой N в шапке чата: серый — шифрование низкое, жёлтый — среднее, зелёный — максимальное.'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                for (final m in LinkMode.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_outlined, color: m.colorOn(cs)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Заголовок строки — только уровень шифрования;
                              // сокращение SB/RT/P2P добавляем в режиме
                              // разработчика (отзыв владельца 22.11, 19:13).
                              Text(
                                [
                                  '${tr('Шифрование')}: ${m.encryptionLevel}',
                                  if (friendlyErrorDevMode) m.label,
                                  if (m == current) tr('сейчас'),
                                ].join(' · '),
                                style: TextStyle(
                                    fontWeight: m == current
                                        ? FontWeight.w700
                                        : FontWeight.w500),
                              ),
                              const SizedBox(height: 2),
                              Text(m.encryptionNote,
                                  style: Theme.of(ctx).textTheme.bodySmall),
                              if (friendlyErrorDevMode) ...[
                                const SizedBox(height: 2),
                                Text(m.description,
                                    style: Theme.of(ctx)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: cs.onSurfaceVariant
                                                .withValues(alpha: 0.8))),
                              ],
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = mode.colorOn(cs);
    // Сокращений SB/RT/P2P в шапке нет вообще — ни для пользователя, ни в
    // режиме разработчика (отзыв 23.11: «в шапке щит с буквой н, а правее
    // п2п или сб — исправь, оставь только щит»). Состояние читается по
    // цвету щита, подробности — в диалоге по нажатию.
    return Semantics(
      button: true,
      label: '${tr('Щит связи')}: ${mode.encryptionLevel}',
      child: GestureDetector(
        onTap: () => explain(context, mode),
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          // Подпись даём через Semantics выше, иначе Tooltip прочитают дважды.
          excludeFromSemantics: true,
          message:
              '${tr('Шифрование')}: ${mode.encryptionLevel}\n${mode.encryptionNote}',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Щит и «N» — один значок: буква по центру щита.
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(Icons.shield_outlined, size: _shieldSize, color: color),
                    // Отзыв 23.11: «буквоку н в щите как будто надо на пару
                    // пикселей выше двинуть». Было Padding top: 1 (буква на
                    // 1 px ниже центра); теперь центр щита минус 1 px —
                    // ровно на 2 px выше, чем было, и на 18 px щите буква
                    // (высота ≈9 px) остаётся внутри контура.
                    Transform.translate(
                      offset: const Offset(0, -1),
                      child: Text(
                        'N',
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: color,
                            height: 1),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}