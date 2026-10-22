import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

import 'pdf_lite.dart';

/// Разбор PDF-отчётов тренировок SCATT Expert.
///
/// Файл принимается только если он сам себя называет отчётом SCATT (метаданные), имеет ожидаемую
/// структуру страниц и все проверки сходятся (число выстрелов, суммы по сериям и общая, диапазон
/// 0…10.9, нумерация, соответствие балла пробоине). Любой другой PDF — [ScattNotRecognized]:
/// без догадок и без частичного разбора.
class ScattNotRecognized implements Exception {
  final String reason;
  const ScattNotRecognized(this.reason);
  @override
  String toString() => reason;
}

class _Target {
  final String code;
  final double r10; // радиус «десятки», мм
  final double step; // шаг кольца, мм
  final double cal; // калибр, мм
  final String name;
  const _Target(this.code, this.r10, this.step, this.cal, this.name);
}

const _targets = {
  'rifle_50m': _Target('rifle_50m', 5.2, 8.0, 5.6, 'МВ 50 м'),
  'rifle_10m': _Target('rifle_10m', 0.25, 2.5, 4.5, 'ВП 10 м'),
  'pistol_10m': _Target('pistol_10m', 5.75, 8.0, 4.5, 'ПП 10 м'),
  'pistol_25m': _Target('pistol_25m', 25.0, 25.0, 5.6, 'МП 25 м'),
};

const scattColumns = [
  'score',
  'aim_time_s',
  'ten0_pct',
  'ten_a0_pct',
  'z_pct',
  'z_plus_pct',
  'z2_pct',
  'z2_plus_pct',
  'speed_mm_s',
  'speed_025_mm_s',
  'col12',
];

class ScattShot {
  final int no;
  final bool marked;
  final Map<String, double> cols;
  double xMm = 0, yMm = 0, calc = 0;
  ScattShot(this.no, this.marked, this.cols);
  double get score => cols['score']!;
}

class ScattSeries {
  final String title;
  final bool sighter;
  final int no;
  final double? sum;
  final List<ScattShot> shots;
  const ScattSeries(this.title, this.sighter, this.no, this.sum, this.shots);
}

class ScattReport {
  final String athlete;
  final DateTime started; // местное время устройства
  final String weapon;
  final double distance;
  final double caliber;
  final double total;
  final int totalInt;
  final int nSeries;
  final int nShots;
  final Map<String, String> summary;
  final String stance; // standing | kneeling | prone | ''
  final String stanceRu;
  final String stanceHow; // mask | shape | ''
  final String discipline; // код мишени
  final List<ScattSeries> series;
  final List<String> problems;

  const ScattReport({
    required this.athlete,
    required this.started,
    required this.weapon,
    required this.distance,
    required this.caliber,
    required this.total,
    required this.totalInt,
    required this.nSeries,
    required this.nShots,
    required this.summary,
    required this.stance,
    required this.stanceRu,
    required this.stanceHow,
    required this.discipline,
    required this.series,
    required this.problems,
  });

  String get targetName => _targets[discipline]!.name;
  String get exerciseName => stanceRu.isEmpty ? targetName : '$targetName, $stanceRu';
  Iterable<ScattShot> get countingShots => series.where((s) => !s.sighter).expand((s) => s.shots);

  /// Ключ тренировки: по нему находят повторный импорт того же отчёта.
  String get key => 'scatt-pdf:$athlete:${_iso(started)}:$total:$nShots';

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_2(d.month)}-${_2(d.day)}T${_2(d.hour)}:${_2(d.minute)}';
  static String _2(int v) => v.toString().padLeft(2, '0');

  bool get hasProblems => problems.isNotEmpty;

  /// Тренировка в формате обычного импорта (`SessionImport`).
  Map<String, dynamic> toSessionJson() {
    final t = _targets[discipline]!;
    final startedIso = started.toIso8601String();
    return {
      'exercise': {
        'name': exerciseName,
        'target_face_code': discipline,
        'total_shots': nShots,
        'series_size': 10,
      },
      'started_at': startedIso,
      'finished_at': started.add(_totalDuration(summary['total_time'])).toIso8601String(),
      'extra': {
        'импорт_ключ': key,
        'scatt': {
          'athlete': athlete,
          'weapon': weapon,
          'total': total,
          'total_int': totalInt,
          'stance': stance,
          'series_sums': [for (final s in series) if (!s.sighter) s.sum],
          ...summary,
        },
      },
      'shots': [
        for (final s in series.where((s) => !s.sighter))
          for (final r in s.shots)
            {
              'n': r.no,
              'series': s.no,
              'score': r.score,
              'x_mm': double.parse(r.xMm.toStringAsFixed(2)),
              'y_mm': double.parse(r.yMm.toStringAsFixed(2)),
              'counts': true,
              'extra': {
                'scatt': {
                  for (final c in scattColumns)
                    if (c != 'score') c: r.cols[c],
                  if (r.marked) 'marked_star': true,
                  'calc_score': r.calc,
                  'caliber_mm': t.cal,
                },
              },
            },
      ],
    };
  }
}

// ---------------------------------------------------------------------------

Duration _totalDuration(String? s) {
  final m = RegExp(r'^(\d+):(\d{2})(?::(\d{2}))?$').firstMatch((s ?? '').trim());
  if (m == null) return Duration.zero;
  final a = int.parse(m[1]!), b = int.parse(m[2]!), c = m[3] == null ? null : int.parse(m[3]!);
  return c == null ? Duration(minutes: a, seconds: b) : Duration(hours: a, minutes: b, seconds: c);
}

final _numRe = RegExp(r'^\d+\*?$');

double? _num(String s) => double.tryParse(s.replaceAll('%', '').replaceAll(',', '.'));

String _clean(String s) => s.replaceAll(RegExp(r'[\s ]+'), ' ').trim();

(String?, String?) _disciplineOf(String weapon, double dist) {
  final w = weapon.toLowerCase();
  final pistol = w.contains('пистолет');
  final rifle = w.contains('винтовка');
  if (!pistol && !rifle) return (null, 'оружие «$weapon» не распознано');
  final d = (dist * 10).round() / 10;
  final code = rifle
      ? (d == 10.0 ? 'rifle_10m' : (d == 50.0 ? 'rifle_50m' : null))
      : (d == 10.0 ? 'pistol_10m' : (d == 25.0 ? 'pistol_25m' : null));
  if (code == null) return (null, 'нет мишени для «$weapon» на ${d.toStringAsFixed(0)} м');
  return (code, null);
}

double _calcScore(double rMm, _Target t) {
  final rc = rMm - t.cal / 2;
  final s = 10 + ((t.r10 - rc) / (t.step / 10) + 1e-9).floorToDouble() / 10;
  return math.max(0.0, math.min(10.9, (s * 10).round() / 10));
}

// Значок изготовки: маска картинки (md5 несжатых отсчётов, первые 8 знаков).
const _stanceByMask = {
  '3e0e7e8d': ('standing', 'стоя'),
  '19344c85': ('kneeling', 'с колена'),
  'd53349c2': ('prone', 'лёжа'),
};

(String, String, String) _stance(PdfLiteDoc doc, PdfPageContent page0) {
  for (final im in page0.images) {
    final top = page0.height - im.y1;
    if (im.x0 > 380 && im.x0 < 420 && top < 120 && im.ref != null) {
      final d = doc.dictOf(im.ref);
      final sm = doc.resolve(d['SMask']);
      if (sm is! PdfStream) return ('', '', '');
      final w = doc.resolve(sm.dict['Width']), h = doc.resolve(sm.dict['Height']);
      final bpc = doc.resolve(sm.dict['BitsPerComponent']);
      if (w is! int || h is! int || w <= 0 || h <= 0 || w * h > 1 << 20 || bpc != 8) return ('', '', '');
      final raw = doc.streamData(sm, maxCompressed: 1 << 20, maxOut: 2 << 20);
      if (raw.length != w * h) return ('', '', '');
      final hash = md5.convert(raw).toString().substring(0, 8);
      final known = _stanceByMask[hash];
      if (known != null) return (known.$1, known.$2, 'mask');
      // Значок нарисован иначе (другой размер/сжатие) — классифицируем по форме и сообщаем об этом.
      var total = 0, low = 0;
      int? top0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (raw[y * w + x] > 128) {
            total++;
            if (y >= (h * 0.7).floor()) low++;
            if (x >= w ~/ 2) top0 ??= y;
          }
        }
      }
      if (total == 0) return ('', '', '');
      final aspect = h / w;
      final head = top0 == null ? 1.0 : top0 / h;
      final lowShare = low / total;
      if (aspect < 0.8) return ('prone', 'лёжа', 'shape');
      if (head < 0.14 && lowShare < 0.245) return ('standing', 'стоя', 'shape');
      if (head >= 0.14 && lowShare >= 0.245) return ('kneeling', 'с колена', 'shape');
      return ('', '', '');
    }
  }
  return ('', '', '');
}

List<PdfTextBlock> _visible(PdfPageContent c) => [
      for (final b in c.blocks)
        if (b.x >= 0 && b.x <= c.width && b.y >= 0 && b.y <= c.height) b,
    ];

List<String> _lines(PdfPageContent c) => [
      for (final b in _visible(c))
        if (_clean(b.text).isNotEmpty) _clean(b.text),
    ];

/// Разбирает PDF. Бросает [ScattNotRecognized], если это не отчёт SCATT (или не такой, какой
/// понимаем). Замечания по содержимому (не сошлись суммы и т. п.) попадают в [ScattReport.problems].
ScattReport parseScattPdf(Uint8List bytes) {
  final PdfLiteDoc doc;
  try {
    doc = PdfLiteDoc.open(bytes);
  } on PdfLiteException catch (e) {
    throw ScattNotRecognized(e.message);
  }
  try {
    return _parse(doc);
  } on PdfLiteException catch (e) {
    throw ScattNotRecognized(e.message);
  } on ScattNotRecognized {
    rethrow;
  } on RangeError {
    throw const ScattNotRecognized('структура отчёта не совпала');
  } on StateError {
    throw const ScattNotRecognized('структура отчёта не совпала');
  } on FormatException {
    throw const ScattNotRecognized('структура отчёта не совпала');
  }
}

ScattReport _parse(PdfLiteDoc doc) {
  // 1. Файл называет себя отчётом SCATT — до любой распаковки.
  final info = doc.info();
  if (!(info['Creator'] ?? '').toUpperCase().contains('SCATT')) {
    throw const ScattNotRecognized('не отчёт тренировки');
  }
  final pages = doc.pages();
  if (pages.length < 2 || pages.length > 200) throw const ScattNotRecognized('неожиданное число страниц');

  // 2. Первая страница: шапка.
  final p0 = doc.content(pages.first);
  final lines = _lines(p0);
  final all = lines.join('\n');
  if (!all.contains('Общая сумма') || !all.contains('Серий:') || !all.contains('Выстрелов:')) {
    throw const ScattNotRecognized('нет шапки отчёта');
  }
  final athlete = lines.first;
  final dm = lines.map((l) => RegExp(r'^(\d\d)\.(\d\d)\.(\d{4}) (\d\d):(\d\d)').firstMatch(l)).firstWhere((m) => m != null, orElse: () => null);
  if (dm == null) throw const ScattNotRecognized('нет даты тренировки');
  final started = DateTime(int.parse(dm[3]!), int.parse(dm[2]!), int.parse(dm[1]!), int.parse(dm[4]!), int.parse(dm[5]!));
  final weapon = lines[2];
  final distLine = lines.firstWhere((l) => RegExp(r'^[\d.]+ m$').hasMatch(l), orElse: () => '');
  final calLine = lines.firstWhere((l) => RegExp(r'^[\d.]+ mm$').hasMatch(l), orElse: () => '');
  final dist = _num(distLine.split(' ').first);
  final cal = _num(calLine.split(' ').first);
  final i = lines.indexOf('Общая сумма');
  if (dist == null || cal == null || i < 0 || i + 2 >= lines.length) throw const ScattNotRecognized('шапка отчёта не разобрана');
  final total = _num(lines[i + 1]);
  final totalIntD = _num(lines[i + 2]);
  final mm = RegExp(r'Серий:\s*(\d+)\s*Выстрелов:\s*(\d+)').firstMatch(all);
  if (total == null || totalIntD == null || mm == null) throw const ScattNotRecognized('шапка отчёта не разобрана');
  final summary = <String, String>{};
  for (final e in {'Общее время': 'total_time', 'Прицеливания': 'aim_time', 'Стабильность темпа': 'tempo_stability', 'Размер группы': 'group_mm'}.entries) {
    final k = lines.indexOf(e.key);
    if (k >= 0 && k + 1 < lines.length) summary[e.value] = lines[k + 1];
  }
  final (stance, stanceRu, stanceHow) = _stance(doc, p0);
  final (disc, discProblem) = _disciplineOf(weapon, dist);
  if (disc == null) throw ScattNotRecognized(discProblem!);
  final t = _targets[disc]!;
  final nSeries = int.parse(mm[1]!), nShots = int.parse(mm[2]!);
  if (nShots <= 0 || nShots > 1000 || nSeries <= 0 || nSeries > 200) throw const ScattNotRecognized('нереальное число выстрелов');

  final problems = <String>[];
  final series = <ScattSeries>[];
  var sighters = 0;
  for (var pn = 1; pn < pages.length; pn++) {
    final c = doc.content(pages[pn]);
    final vis = _visible(c);
    if (vis.isEmpty) continue;
    final title = _clean(vis.first.text);
    final m = RegExp(r'^(Серия|Пристрелка)\s*(\d*)$').firstMatch(title);
    if (m == null) continue;
    final sighter = m[1] == 'Пристрелка';
    final parsed = _seriesPage(c, vis, t, cal, title, problems);
    if (sighter) sighters += parsed.rows.length;
    series.add(ScattSeries(title, sighter, int.tryParse(m[2] ?? '') ?? 0, parsed.sum, parsed.rows));
  }
  if (sighters > 0) problems.add('в отчёте есть пристрелка — такой импорт пока не поддерживается');

  final match = series.where((s) => !s.sighter).toList();
  final allShots = [for (final s in match) ...s.shots];
  if (allShots.length != nShots) problems.add('выстрелов ${allShots.length}, в отчёте $nShots');
  if (match.length != nSeries) problems.add('серий ${match.length}, в отчёте $nSeries');
  final sumScores = allShots.fold<double>(0, (a, r) => a + r.score);
  if ((sumScores - total).abs() > 0.05) problems.add('сумма ${sumScores.toStringAsFixed(1)} ≠ $total');
  final sumInt = allShots.fold<int>(0, (a, r) => a + r.score.truncate());
  if (sumInt != totalIntD.round()) problems.add('сумма целыми $sumInt ≠ ${totalIntD.round()}');
  final nos = [for (final r in allShots) r.no];
  for (var k = 0; k < nos.length; k++) {
    if (nos[k] != k + 1) {
      problems.add('нумерация выстрелов с дырами/повторами');
      break;
    }
  }
  if (stance.isEmpty) {
    problems.add('изготовка не распознана');
  } else if (stanceHow == 'shape') {
    problems.add('изготовка «$stanceRu» определена по форме значка — проверьте глазами');
  }
  if (allShots.any((r) => r.score < 0 || r.score > 10.9)) problems.add('балл вне 0…10.9');

  return ScattReport(
    athlete: athlete,
    started: started,
    weapon: weapon,
    distance: dist,
    caliber: cal,
    total: total,
    totalInt: totalIntD.round(),
    nSeries: nSeries,
    nShots: nShots,
    summary: summary,
    stance: stance,
    stanceRu: stanceRu,
    stanceHow: stanceHow,
    discipline: disc,
    series: series,
    problems: problems,
  );
}

({List<ScattShot> rows, double? sum}) _seriesPage(PdfPageContent c, List<PdfTextBlock> vis, _Target t, double cal, String title, List<String> problems) {
  final holes = <(double, double, double)>[];
  final rings = <(double, double, double)>[];
  for (final p in c.paths) {
    if ((p.width - p.height).abs() > 0.5) continue;
    final cx = (p.x0 + p.x1) / 2, cy = (p.y0 + p.y1) / 2;
    if (p.fill && p.stroke && p.fillColor != null && p.fillColor!.reduce(math.min) > 0.99) {
      holes.add((cx, cy, p.width));
    } else if (!p.fill && p.stroke) {
      rings.add((cx, cy, p.width));
    }
  }
  if (holes.isEmpty || rings.isEmpty) throw ScattNotRecognized('$title: не нашёл пробоины/кольца');
  final cxs = [for (final r in rings) r.$1]..sort();
  final cys = [for (final r in rings) r.$2]..sort();
  final ccx = cxs[cxs.length ~/ 2], ccy = cys[cys.length ~/ 2];
  final hd = ([for (final h in holes) h.$3]..sort())[holes.length ~/ 2];
  final ptPerMm = hd / cal;
  // Сверка масштаба по кольцам: самый частый шаг между радиусами = шаг кольца в мм.
  final radii = {for (final r in rings) (r.$3 / 2 * 100).round() / 100}.toList()..sort();
  final diffs = <double>[for (var k = 0; k + 1 < radii.length; k++) if (radii[k + 1] - radii[k] > 1) (((radii[k + 1] - radii[k]) * 10).round() / 10)];
  if (diffs.isNotEmpty) {
    final counts = <double, int>{};
    for (final d in diffs) {
      counts[d] = (counts[d] ?? 0) + 1;
    }
    final stepPt = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final ringScale = stepPt / t.step;
    if ((ringScale - ptPerMm).abs() / ptPerMm > 0.02) {
      throw ScattNotRecognized('$title: масштаб по пробоине не совпал со шкалой колец');
    }
  }
  final pts = [for (final h in holes) ((h.$1 - ccx) / ptPerMm, (h.$2 - ccy) / ptPerMm)]; // Y вверх

  // Таблица: слова по строкам (одинаковая базовая линия), слева направо.
  final sorted = [...vis]..sort((a, b) => b.y.compareTo(a.y)); // сверху вниз
  final groups = <List<PdfTextBlock>>[];
  for (final b in sorted) {
    if (groups.isNotEmpty && (groups.last.first.y - b.y).abs() <= 0.15) {
      groups.last.add(b);
    } else {
      groups.add([b]);
    }
  }
  final rows = <ScattShot>[];
  double? seriesSum;
  for (final g in groups) {
    final blocks = g..sort((a, b) => a.x.compareTo(b.x));
    final toks = <String>[for (final b in blocks) ..._clean(b.text).split(' ').where((w) => w.isNotEmpty)];
    if (toks.length == scattColumns.length + 1 && _numRe.hasMatch(toks[0])) {
      final vals = [for (final x in toks.skip(1)) _num(x)];
      if (vals.any((v) => v == null)) continue;
      rows.add(ScattShot(int.parse(toks[0].replaceAll('*', '')), toks[0].endsWith('*'), {for (var j = 0; j < scattColumns.length; j++) scattColumns[j]: vals[j]!}));
    } else if (toks.length == scattColumns.length && RegExp(r'^\d+\.\d$').hasMatch(toks[0]) && seriesSum == null && rows.isNotEmpty) {
      seriesSum = _num(toks[0]);
    }
  }
  if (pts.length != rows.length) problems.add('$title: пробоин ${pts.length}, строк в таблице ${rows.length}');
  final n = math.min(pts.length, rows.length);
  for (var j = 0; j < n; j++) {
    rows[j].xMm = pts[j].$1;
    rows[j].yMm = pts[j].$2;
    rows[j].calc = _calcScore(math.sqrt(pts[j].$1 * pts[j].$1 + pts[j].$2 * pts[j].$2), t);
    if ((rows[j].calc - rows[j].score).abs() > 0.25) {
      problems.add('$title выстр.${rows[j].no}: в таблице ${rows[j].score}, по пробоине ${rows[j].calc}');
    }
  }
  if (seriesSum != null && !title.startsWith('Пристрелка')) {
    final s = rows.fold<double>(0, (a, r) => a + r.score);
    if ((s - seriesSum).abs() > 0.05) problems.add('$title: сумма строк ${s.toStringAsFixed(1)} ≠ «Сумма серии» $seriesSum');
  }
  return (rows: rows, sum: seriesSum);
}

/// Разбор в «простой» вид для передачи между изолятами и для показа.
Map<String, dynamic> scattToMap(ScattReport r) => {
      'ok': true,
      'key': r.key,
      'athlete': r.athlete,
      'started': r.started.toIso8601String(),
      'exercise': r.exerciseName,
      'discipline': r.discipline,
      'stance': r.stance,
      'stance_how': r.stanceHow,
      'n_shots': r.nShots,
      'total': r.total,
      'problems': r.problems,
      'session': r.toSessionJson(),
    };

/// Разбор одного файла для пакетной загрузки: никогда не бросает — файл либо отчёт, либо нет.
Map<String, dynamic> scattTryParse(Uint8List bytes) {
  try {
    return scattToMap(parseScattPdf(bytes));
  } on ScattNotRecognized catch (e) {
    return {'ok': false, 'reason': e.reason};
  } catch (_) {
    return {'ok': false, 'reason': 'не удалось прочитать файл'};
  }
}

String scattJsonOf(Map<String, dynamic> parsed) => jsonEncode(parsed['session']);
