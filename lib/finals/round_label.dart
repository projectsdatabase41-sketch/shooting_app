import '../i18n/i18n.dart';

/// Подпись раунда на экране: «Серия 2», «Выстрел 3»; у винтовки 50 м в трёх положениях ещё и
/// положение — «Колено, серия 2 из 3».
String finalRoundLabel(String formatId, String round) {
  final n = round.split(':').last;
  if (!round.startsWith('series')) return tr('Выстрел {n}', {'n': n});
  final k = int.tryParse(n) ?? 0;
  if (formatId == 'rifle_3p_50m' && k >= 1 && k <= 8) {
    final (pos, idx, of) = k <= 3 ? (tr('Колено'), k, 3) : (k <= 6 ? (tr('Лёжа'), k - 3, 3) : (tr('Стоя'), k - 6, 2));
    return tr('{pos}, серия {k} из {of}', {'pos': pos, 'k': idx, 'of': of});
  }
  return tr('Серия {n}', {'n': n});
}
