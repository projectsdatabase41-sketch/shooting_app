import 'dart:math' as math;

import '../i18n/i18n.dart';
import '../logic/friendly_error.dart';
/// Справочник мишеней ISSF (раздел 3 tech-spec-v2.md).
///
/// Калибр пробоины берётся из конкретной мишени, не общий на всё
/// приложение — пневматика и мелкашка визуально и по расчётам различаются.
///
/// **Кольца — `ringDiametersMm`.** Реальные официальные диаметры границ
/// колец 10..1 (мм), взятые из регламентов (Приказ Минспорта РФ,
/// зеркалирующий технические правила ISSF/МФСС для соответствующих
/// мишеней), а не вычисленные делением яблока на равные доли. Индекс 0 —
/// граница десятки, индекс 9 — граница единицы. Используются как
/// `scoring.dart` (расчёт очков), так и `target_painter.dart` (отрисовка
/// линий колец) — единственный источник истины для геометрии, чтобы
/// рисунок и подсчёт очков не могли разойтись.
///
/// Источники (сверено в сентябре 2026, перепроверено повторно по
/// нескольким независимым источникам после того, как первая проверка
/// пропустила две ошибки — см. ниже):
/// - № 8, винтовка 10 м: consultant.ru cons_doc_LAW_291887 ("РАЗМЕРЫ
///   МИШЕНИ N 8 И ЕЕ ЭЛЕМЕНТОВ, ММ") + Таблица 1.1 (cons_doc_LAW_222178)
///   + airgun.org.ru/competitions/misheni.pdf + печатный бланк
///   мишени (hunter122.narod.ru) — шаг 5 мм диаметра/кольцо, бланк
///   80×80мм (4 независимых источника). Бланк ИСПРАВЛЕН с 170мм на
///   80мм — 170мм было ошибочным чтением одного AI-пересказа Wikipedia,
///   не перепроверенным при первой проверке; поймано по скриншоту
///   печатного бланка от пользователя.
/// - № 9, пистолет 10 м: Таблица 1.1 (cons_doc_LAW_222178) +
///   airgun.org.ru PDF + розничные листинги мишеней (pnevmat24.ru,
///   opticstrade.com, strike.by, victor-shop.ru — все указывают
///   "170×170мм" на упаковке) — бланк 170×170мм (много источников,
///   высокая уверенность). Диаметр яблока ИСПРАВЛЕН с 26.5мм на
///   59.5мм (по Таблице 1.1 + PDF, 2 источника) — 26.5мм было ошибкой
///   первой проверки; 59.5мм совпадает с официальной границей кольца 7
///   (см. ringDiametersMm ниже), т.е. яблоко у № 9 — это кольца 10..7.
/// - № 7 (НЕ № 12 — распространённая ошибка нумерации, № 12с — это
///   вообще другая, ростовая мишень для тактической стрельбы), винтовка
///   50 м: consultant.ru cons_doc_LAW_221407 ("мишень для стрельбы из
///   винтовки на 50 м", явно № 7) + Таблица 1.1 + airgun.org.ru PDF —
///   шаг 16 мм диаметра/кольцо, бланк 250мм (регламент: "не менее",
///   отдельные типографские бланки печатают чуть меньше, например
///   230×230мм — не противоречие, а допустимый разброс печати).
/// - № 4 (подтверждено — это верный номер для дистанции 25м/50м,
///   отдельная № 5 — это "появляющаяся" мишень для дуэльной/скоростной
///   стрельбы, другая дисциплина), пистолет 25/50 м: consultant.ru
///   cons_doc_LAW_291471 ("Мишень для стрельбы из пистолета на 25 м. и
///   50 м.") + Таблица 1.1 + airgun.org.ru PDF — шаг 50 мм
///   диаметра/кольцо, бланк 550×(520..550) мм.
/// Метод измерения достоинства выстрела.
///
/// Заведён отдельным параметром мишени по требованию ТЗ («у каждой
/// мишени свой калибр и свой метод измерения») — чтобы это было
/// настройкой в справочнике, а не зашитым в алгоритм решением.
enum GaugingMethod {
  /// «Вовнутрь» (inward): достоинство определяется по краю пробоины,
  /// БЛИЖАЙШЕМУ к центру мишени. `R_calc = R_center − радиус_пули`.
  inward,

  /// «Наружу» (outward): достоинство определяется по краю пробоины,
  /// ДАЛЬНЕМУ от центра — пробоина должна целиком помещаться в зону.
  /// `R_calc = R_center + радиус_пули`.
  outward,
}

/// Зона очков многоугольной мишени (IPSC): выпуклый контур в мм относительно
/// центра габарита мишени, y вверх (как у выстрела), и очки за попадание.
class ScoreZone {
  final int points;
  final List<List<double>> poly; // [[x, y], ...]
  const ScoreZone(this.points, this.poly);

  /// Из чертежа: точки в см от левого верхнего угла габарита [w]×[h] см.
  factory ScoreZone.cm(int points, List<List<double>> pts, double w, double h) =>
      ScoreZone(points, [
        for (final p in pts) [(p[0] - w / 2) * 10, (h / 2 - p[1]) * 10]
      ]);

  /// Контур, сдвинутый внутрь на [dMm] (выпуклый многоугольник).
  ScoreZone inset(double dMm) {
    final n = poly.length;
    var area = 0.0;
    for (var i = 0; i < n; i++) {
      final a = poly[i], b = poly[(i + 1) % n];
      area += a[0] * b[1] - b[0] * a[1];
    }
    final s = area > 0 ? 1.0 : -1.0; // + против часовой
    // Линии рёбер, сдвинутые внутрь: n·p = c.
    final lines = <List<double>>[];
    for (var i = 0; i < n; i++) {
      final a = poly[i], b = poly[(i + 1) % n];
      final dx = b[0] - a[0], dy = b[1] - a[1];
      final len = math.sqrt(dx * dx + dy * dy);
      final nx = -dy / len * s, ny = dx / len * s; // внутрь
      lines.add([nx, ny, nx * a[0] + ny * a[1] + dMm]);
    }
    final out = <List<double>>[];
    for (var i = 0; i < n; i++) {
      final l1 = lines[(i + n - 1) % n], l2 = lines[i];
      final det = l1[0] * l2[1] - l1[1] * l2[0];
      out.add([
        (l1[2] * l2[1] - l1[1] * l2[2]) / det,
        (l1[0] * l2[2] - l1[2] * l2[0]) / det,
      ]);
    }
    return ScoreZone(points, out);
  }

  /// Точка внутри или на границе выпуклого контура.
  bool contains(double x, double y) {
    var pos = false, neg = false;
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final c = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
      if (c > 1e-9) pos = true;
      if (c < -1e-9) neg = true;
    }
    return !(pos && neg);
  }

  Map<String, dynamic> toJson() => {'points': points, 'poly': poly};
  factory ScoreZone.fromJson(Map<String, dynamic> j) => ScoreZone(
        j['points'] as int,
        [
          for (final p in j['poly'] as List)
            [for (final v in p as List) (v as num).toDouble()]
        ],
      );
}

class TargetFace {
  final String code;
  /// Название по-русски — ключ перевода; [name] — на языке интерфейса.
  final String nameKey;
  String get name => tr(nameKey);
  final double distanceM;
  final double caliberMm;
  final double bullseyeDiameterMm; // диаметр чёрного яблока (визуальный, для отрисовки)
  final double? blankSizeMm; // размер бланка мишени, если задан

  /// Официальные диаметры границ колец, мм, от кольца 10 (индекс 0) до
  /// кольца 1 (индекс 9). Ровно 10 значений.
  final List<double> ringDiametersMm;

  /// Диаметр ВНУТРЕННЕЙ ДЕСЯТКИ, мм, — самая маленькая окружность на
  /// бланке, внутри габарита 10 (ISSF: "inner ten", в русских правилах
  /// также "центральная десятка"). `null` — окружность на этой мишени не
  /// печатается и рисовать её не нужно.
  ///
  /// На подсчёт очков НЕ влияет: у нас десятые доли считаются по модели
  /// вложенных колец пробоины (см. `logic/scoring.dart`), а внутренняя
  /// десятка в правилах ISSF нужна для разбора равных результатов при
  /// целочисленном подсчёте. Здесь это чисто элемент разметки бланка.
  ///
  /// Источники (сверено по 5-6 независимым источникам на каждое число:
  /// ISSF General Technical Rules — официальный русский перевод
  /// shooting-russia.ru и оригинал на swissshooting.ch; USAS GTR;
  /// airgun.org.ru/competitions/misheni.pdf; правила федерации
  /// bssf-shooting.by; для № 7 дополнительно consultant.ru
  /// cons_doc_LAW_221407, где рядом стоит совпадающая с нашей граница
  /// кольца 10 = 10.4мм):
  /// - № 8 (винтовка 10м) — отдельной окружности НЕТ. Внутренняя
  ///   десятка там определяется не линией на бланке, а процедурой:
  ///   десятка считается внутренней, если белая точка 0.5мм выбита
  ///   полностью (проверяется калибромером). Рисовать нечего → null.
  /// - № 9 (пистолет 10м) — 5.0 мм (±0.1).
  /// - № 7 (винтовка 50м) — 5.0 мм (±0.1). Совпало с замером по фото
  ///   реального бланка от пользователя (отношение к габариту 10:
  ///   официально 5/10.4 = 0.48, по фото ≈ 0.41).
  /// - № 4 (пистолет 25/50м) — 25 мм (±0.2).
  final double? innerTenDiameterMm;

  /// Метод измерения для ЭТОЙ мишени.
  ///
  /// У всех четырёх — `inward`. Разбирался отдельно, потому что в ТЗ
  /// утверждалось, что пистолетные мишени считаются «наружу»:
  ///
  /// - Деление на inward/outward в правилах ISSF (Приложение «Rules for
  ///   Paper Target Scoring», п. 1.4.4–1.4.9) идёт НЕ по дисциплинам, а
  ///   по размеру кольца, и присутствует в обеих: у винтовки 10 м
  ///   «вовнутрь» меряют кольца 1–2, а кольца 3–10 — «наружу»; у
  ///   пистолета «вовнутрь» кольцо 1, «наружу» кольца 2–10. Более того,
  ///   внутреннюю десятку винтовки правила прямо велят мерить
  ///   ПИСТОЛЕТНЫМ калибромером «наружу» (п. 6.3.4.3).
  /// - Эти пункты описывают измерение БУМАЖНОЙ мишени физическим
  ///   калибромером и дают целые очки. Десятые доли по правилам
  ///   считает только электронная установка (п. 1.3.2 / 6.3.3.1), для
  ///   которой ISSF задаёт лишь требуемую точность, а не формулу.
  /// - Независимые реализации (CMP, разборы алгоритмов сторонних
  ///   систем) описывают для пистолета то же ВЫЧИТАНИЕ радиуса пули.
  /// - Решающий довод — арифметика: при сложении минимально возможный
  ///   `R_calc` для пневматического пистолета равен радиусу пули
  ///   2.25 мм даже при идеальном попадании в центр, и результат
  ///   упирается в 10.4 — то есть 10.9 становится недостижимой в
  ///   принципе. В финалах её выбивают регулярно.
  ///
  /// Поле оставлено настраиваемым: если появятся источники за
  /// «наружу» для конкретной мишени, меняется одна строка, алгоритм
  /// оба варианта уже умеет.
  final GaugingMethod gauging;

  /// Целочисленный подсчёт (стрельба из лука): десятых долей нет, результат
  /// — номер зоны. Касание линии стрелой даёт высшую зону — это тот же
  /// `inward`, а «калибр» мишени — диаметр древка стрелы.
  final bool integerScoring;

  /// Многоугольные зоны (IPSC), от лучшей к худшей. Пусто — кольцевая мишень.
  final List<ScoreZone> zones;

  /// Внешний контур многоугольной мишени (для отрисовки).
  final ScoreZone? outline;

  const TargetFace({
    required this.code,
    required String name,
    required this.distanceM,
    required this.caliberMm,
    required this.bullseyeDiameterMm,
    required this.ringDiametersMm,
    this.blankSizeMm,
    this.innerTenDiameterMm,
    this.gauging = GaugingMethod.inward,
    this.integerScoring = false,
    this.zones = const [],
    this.outline,
  }) : nameKey = name;

  double get caliberRadiusMm => caliberMm / 2;
  double get bullseyeRadiusMm => bullseyeDiameterMm / 2;

  /// Официальные радиусы границ колец, мм: индекс 0 = граница 10,
  /// индекс 9 = граница 1.
  List<double> get ringRadiiMm =>
      List<double>.unmodifiable(ringDiametersMm.map((d) => d / 2));

  /// Радиус внутренней десятки, мм, либо null — см. `innerTenDiameterMm`.
  double? get innerTenRadiusMm =>
      innerTenDiameterMm == null ? null : innerTenDiameterMm! / 2;

  /// Ширина одного кольца, мм (у всех четырёх мишеней шаг между
  /// соседними кольцами официально постоянный — см. источники выше).
  /// Берётся по двум внешним кольцам: у компаундных мишеней лука десятка
  /// уже девятки («внутренняя десятка»), а внешние зоны равны.
  double get ringWidthMm {
    final n = ringDiametersMm.length;
    if (n == 1) return ringDiametersMm[0] / 2; // биатлон: единственная зона
    return n >= 2 ? (ringDiametersMm[n - 1] - ringDiametersMm[n - 2]).abs() / 2 : 0;
  }

  /// Цена одной десятой доли очка, мм — одна десятая ширины кольца.
  ///
  /// Единственный источник истины для десятых: от него считает
  /// `logic/scoring.dart` и от него же берётся шаг степперов результата
  /// в `state/target_view_model.dart`. У каждой мишени он свой (№ 8 —
  /// 0.25 мм, № 9 и № 7 — 0.8 мм, № 4 — 2.5 мм); зашивать 0.8 мм от № 7
  /// на всё приложение нельзя.
  double get decimalStepMm => ringWidthMm / 10;

  /// Поправка на калибр со знаком, мм: сколько прибавить к расстоянию
  /// «центр мишени — центр пробоины», чтобы получить `R_calc`.
  /// «Вовнутрь» — минус радиус пули, «наружу» — плюс.
  double get gaugingOffsetMm =>
      gauging == GaugingMethod.inward ? -caliberRadiusMm : caliberRadiusMm;

  /// Радиус мишени в мм для отрисовки (половина бланка, либо запас над
  /// внешним кольцом, если бланк не задан).
  double get faceRadiusMm => (blankSizeMm ?? bullseyeDiameterMm * 6) / 2;

  /// Оружие — для контекста ИИ-ассистента (см. `AiContext`).
  ///
  /// В `name` оружие тоже упомянуто, но зарыто в свободном тексте вместе
  /// с номером мишени ("№ 8, пневматическая винтовка 10 м") — ассистент
  /// не всегда это вытаскивал и путал, из чего стреляет пользователь.
  /// Выведено из кода, а не хранится отдельным полем: типов ровно два, и
  /// дублировать константу под каждую мишень незачем.
  bool get isArchery => code.startsWith('archery');
  bool get isIpsc => code.startsWith('ipsc');
  bool get isBiathlon => code.startsWith('biathlon');

  /// Новые дисциплины, пока скрытые за режимом разработчика.
  bool get devOnly => isArchery || isBiathlon || hitMiss || isIpsc;

  /// Только «попал/мимо» — без точки на мишени (тарелки).
  bool get hitMiss => code == 'clay';

  /// Где записывать промах: за краем бланка, заведомо вне зоны попадания.
  double get missOffsetMm => faceRadiusMm * 0.9;

  /// Максимум за выстрел (для базы).
  double get maxScore =>
      zones.isNotEmpty ? zones.first.points.toDouble() : (integerScoring ? 10 : 10.9);

  String get weaponRu => isArchery
      ? tr('лук')
      : isIpsc
          ? tr('пистолет/ружьё')
          : hitMiss
          ? tr('ружьё')
          : (isBiathlon || code.startsWith('rifle'))
          ? tr('винтовка')
          : tr('пистолет');

  /// Боеприпас — тем же способом и по той же причине, что `weaponRu`.
  /// Выведено из калибра: 4.5 мм — пневматика, 5.6 мм — малокалиберный
  /// патрон .22 LR (других калибров в справочнике нет).
  String get ammoRu => isArchery
      ? tr('лук, стрелы')
      : hitMiss
          ? tr('дробовое оружие, дробь')
          : isBiathlon
          ? tr('малокалиберное оружие, патрон .22 LR')
          : caliberMm <= 4.5 ? tr('пневматическое оружие (воздух/CO₂), пульки') : tr('малокалиберное оружие, патрон .22 LR');

  factory TargetFace.fromJson(Map<String, dynamic> json) => TargetFace(
        code: json['code'] as String,
        name: json['name'] as String,
        distanceM: (json['distance_m'] as num).toDouble(),
        caliberMm: (json['caliber_mm'] as num).toDouble(),
        bullseyeDiameterMm: (json['bullseye_diameter_mm'] as num).toDouble(),
        ringDiametersMm: (json['ring_diameters_mm'] as List)
            .map((v) => (v as num).toDouble())
            .toList(),
        blankSizeMm: json['blank_size_mm'] == null
            ? null
            : (json['blank_size_mm'] as num).toDouble(),
        innerTenDiameterMm: json['inner_ten_diameter_mm'] == null
            ? null
            : (json['inner_ten_diameter_mm'] as num).toDouble(),
        integerScoring: json['integer_scoring'] == true,
        zones: [
          for (final z in (json['zones'] as List? ?? const []))
            ScoreZone.fromJson(z as Map<String, dynamic>)
        ],
        outline: json['outline'] == null
            ? null
            : ScoreZone.fromJson(json['outline'] as Map<String, dynamic>),
        gauging: GaugingMethod.values.firstWhere(
          (g) => g.name == json['gauging'],
          orElse: () => GaugingMethod.inward,
        ),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'distance_m': distanceM,
        'caliber_mm': caliberMm,
        'bullseye_diameter_mm': bullseyeDiameterMm,
        'ring_diameters_mm': ringDiametersMm,
        'blank_size_mm': blankSizeMm,
        'inner_ten_diameter_mm': innerTenDiameterMm,
        'gauging': gauging.name,
        'integer_scoring': integerScoring,
        'zones': [for (final z in zones) z.toJson()],
        'outline': outline?.toJson(),
      };

  // Раздел 3 tech-spec-v2.md — точные размеры, допуск ±0.1мм на реальных
  // мишенях учитывается на этапе отрисовки/калибровки, не в константах.
  static const TargetFace rifle10m = TargetFace(
    code: 'rifle_10m',
    name: /*tr*/ '№ 8, пневматическая винтовка 10 м',
    distanceM: 10,
    caliberMm: 4.5,
    bullseyeDiameterMm: 30.5,
    // Бланк 80×80мм (было ошибочно 170мм — см. комментарий к классу).
    blankSizeMm: 80,
    ringDiametersMm: [0.5, 5.5, 10.5, 15.5, 20.5, 25.5, 30.5, 35.5, 40.5, 45.5],
    // Внутренняя десятка отдельной окружностью НЕ печатается — см.
    // комментарий к полю innerTenDiameterMm.
    innerTenDiameterMm: null,
  );

  static const TargetFace pistol10m = TargetFace(
    code: 'pistol_10m',
    name: /*tr*/ '№ 9, пневматический пистолет 10 м',
    distanceM: 10,
    caliberMm: 4.5,
    // Диаметр яблока 59.5мм (было ошибочно 26.5мм — см. комментарий к
    // классу; совпадает с официальной границей кольца 7).
    bullseyeDiameterMm: 59.5,
    // Официальный размер бланка мишени ISSF для пневматического пистолета
    // 10 м — 170×170 мм (совпадает с бланком винтоночной мишени № 8).
    blankSizeMm: 170,
    ringDiametersMm: [11.5, 27.5, 43.5, 59.5, 75.5, 91.5, 107.5, 123.5, 139.5, 155.5],
    innerTenDiameterMm: 5.0,
  );

  static const TargetFace rifle50m = TargetFace(
    // Было ошибочно подписано "№ 12" — верный номер № 7 (№ 12с — это
    // другая, ростовая мишень для тактической стрельбы, см. комментарий
    // к классу). Код 'rifle_50m' не меняю — внутренний идентификатор,
    // от него зависит exercise.targetFaceCode в БД.
    code: 'rifle_50m',
    name: /*tr*/ '№ 7, малокалиберная винтовка 50 м',
    distanceM: 50,
    caliberMm: 5.6,
    bullseyeDiameterMm: 112.4,
    blankSizeMm: 250,
    ringDiametersMm: [10.4, 26.4, 42.4, 58.4, 74.4, 90.4, 106.4, 122.4, 138.4, 154.4],
    innerTenDiameterMm: 5.0,
  );

  static const TargetFace pistol25m = TargetFace(
    code: 'pistol_25m',
    name: /*tr*/ '№ 4, пистолет 25 м',
    distanceM: 25,
    caliberMm: 5.6,
    bullseyeDiameterMm: 200,
    blankSizeMm: 550,
    ringDiametersMm: [50, 100, 150, 200, 250, 300, 350, 400, 450, 500],
    innerTenDiameterMm: 25,
  );

  // ---- Ещё мишени ISSF (ISSF Rule Book 2026, 6.3.4.x) -------------------
  // Кольца — диаметры границ 10..1 (мм) из таблиц правил. Подсчёт — как у
  // остальных ISSF-мишеней (десятые, inward).

  /// 6.3.4.1: 300 м, винтовка. Калибр правилами ограничен только сверху
  /// (макс. 8 мм) — взят 7.62.
  static const TargetFace rifle300m = TargetFace(
    code: 'rifle_300m',
    name: /*tr*/ 'ISSF: винтовка 300 м',
    distanceM: 300,
    caliberMm: 7.62,
    bullseyeDiameterMm: 600,
    blankSizeMm: 1300,
    ringDiametersMm: [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000],
    innerTenDiameterMm: 50,
  );

  /// 6.3.4.4: 25 м, скоростной пистолет — только кольца 10..5.
  static const TargetFace pistolRapid25m = TargetFace(
    code: 'pistol_25m_rapid',
    name: /*tr*/ 'ISSF: скоростной пистолет 25 м',
    distanceM: 25,
    caliberMm: 5.6,
    bullseyeDiameterMm: 500,
    blankSizeMm: 550,
    ringDiametersMm: [100, 180, 260, 340, 420, 500],
    innerTenDiameterMm: 50,
  );

  /// 6.3.4.7: «бегущий кабан» 50 м. На карточке две зоны (±453 мм от
  /// прицельной метки); здесь — одна зона.
  static const TargetFace moving50m = TargetFace(
    code: 'moving_50m',
    name: /*tr*/ 'ISSF: бегущая мишень 50 м (одна зона)',
    distanceM: 50,
    caliberMm: 5.6,
    bullseyeDiameterMm: 0,
    blankSizeMm: 400,
    ringDiametersMm: [60, 94, 128, 162, 196, 230, 264, 298, 332, 366],
    innerTenDiameterMm: 30,
  );

  /// 6.3.4.8: бегущая мишень 10 м (пневматика), одна зона из двух.
  static const TargetFace moving10m = TargetFace(
    code: 'moving_10m',
    name: /*tr*/ 'ISSF: бегущая мишень 10 м (одна зона)',
    distanceM: 10,
    caliberMm: 4.5,
    bullseyeDiameterMm: 30.5,
    blankSizeMm: 70,
    ringDiametersMm: [5.5, 10.5, 15.5, 20.5, 25.5, 30.5, 35.5, 40.5, 45.5, 50.5],
    innerTenDiameterMm: 0.5,
  );

  // ---- Лук (World Archery) -------------------------------------------
  // Источники: World Archery Rulebook Book 3 (2026-01-27) и Bylaw 8.2.1
  // (Compound Indoor Target Face). Все лица — 10 равных зон; диаметры
  // границ — в мм, от десятки к единице. Внутренняя десятка (X) — половина
  // десятки (122 см: 61 мм, 80 см: 40 мм, 60 см: 30 мм, 40 см: 20 мм).
  // Касание линии = высшая зона (inward), древко ~5.5 мм. Компаундные
  // мишени 60/40 см: десяткой считается ТОЛЬКО внутренняя десятка (3/2 см),
  // остальное кольцо десятки — девятка. Тройная мишень 40 см — 5 колец
  // (10..6), у компаунда десятка тоже внутренняя (20 мм).
  static List<double> _rings(double tenMm, int n) =>
      [for (var i = 1; i <= n; i++) tenMm * i];

  static final TargetFace archery122 = TargetFace(
    code: 'archery_122',
    name: /*tr*/ 'Лук: мишень 122 см (70 м)',
    distanceM: 70,
    caliberMm: 5.5,
    bullseyeDiameterMm: 244,
    blankSizeMm: 1220,
    ringDiametersMm: _rings(122, 10),
    innerTenDiameterMm: 61,
    integerScoring: true,
  );

  static final TargetFace archery80 = TargetFace(
    code: 'archery_80',
    name: /*tr*/ 'Лук: мишень 80 см (50 м)',
    distanceM: 50,
    caliberMm: 5.5,
    bullseyeDiameterMm: 160,
    blankSizeMm: 800,
    ringDiametersMm: _rings(80, 10),
    innerTenDiameterMm: 40,
    integerScoring: true,
  );

  /// 80 см, только 6 внутренних колец (10..5) — компаунд 50 м.
  static final TargetFace archery80Six = TargetFace(
    code: 'archery_80_6',
    name: /*tr*/ 'Лук: 80 см, 6 колец (компаунд, 50 м)',
    distanceM: 50,
    caliberMm: 5.5,
    bullseyeDiameterMm: 160,
    blankSizeMm: 480,
    ringDiametersMm: _rings(80, 6),
    innerTenDiameterMm: 40,
    integerScoring: true,
  );

  static final TargetFace archery60 = TargetFace(
    code: 'archery_60',
    name: /*tr*/ 'Лук: мишень 60 см (25 м)',
    distanceM: 25,
    caliberMm: 5.5,
    bullseyeDiameterMm: 120,
    blankSizeMm: 600,
    ringDiametersMm: _rings(60, 10),
    innerTenDiameterMm: 30,
    integerScoring: true,
  );

  static final TargetFace archery60Compound = TargetFace(
    code: 'archery_60_c',
    name: /*tr*/ 'Лук: 60 см, компаунд (25 м)',
    distanceM: 25,
    caliberMm: 5.5,
    bullseyeDiameterMm: 120,
    blankSizeMm: 600,
    ringDiametersMm: [30, ..._rings(60, 10).skip(1)],
    innerTenDiameterMm: null,
    integerScoring: true,
  );

  static final TargetFace archery40 = TargetFace(
    code: 'archery_40',
    name: /*tr*/ 'Лук: мишень 40 см (18 м)',
    distanceM: 18,
    caliberMm: 5.5,
    bullseyeDiameterMm: 80,
    blankSizeMm: 400,
    ringDiametersMm: _rings(40, 10),
    innerTenDiameterMm: 20,
    integerScoring: true,
  );

  static final TargetFace archery40Compound = TargetFace(
    code: 'archery_40_c',
    name: /*tr*/ 'Лук: 40 см, компаунд (18 м)',
    distanceM: 18,
    caliberMm: 5.5,
    bullseyeDiameterMm: 80,
    blankSizeMm: 400,
    ringDiametersMm: [20, ..._rings(40, 10).skip(1)],
    integerScoring: true,
  );

  /// Одна из трёх мишеней вертикальной «тройки» 40 см: 5 колец (10..6).
  static final TargetFace archery40Triple = TargetFace(
    code: 'archery_40_3',
    name: /*tr*/ 'Лук: 40 см, тройная (18 м)',
    distanceM: 18,
    caliberMm: 5.5,
    bullseyeDiameterMm: 80,
    blankSizeMm: 200,
    ringDiametersMm: _rings(40, 5),
    innerTenDiameterMm: 20,
    integerScoring: true,
  );

  static final TargetFace archery40TripleCompound = TargetFace(
    code: 'archery_40_3_c',
    name: /*tr*/ 'Лук: 40 см, тройная, компаунд (18 м)',
    distanceM: 18,
    caliberMm: 5.5,
    bullseyeDiameterMm: 80,
    blankSizeMm: 200,
    ringDiametersMm: [20, ..._rings(40, 5).skip(1)],
    integerScoring: true,
  );

  // ---- Биатлон (IBU) --------------------------------------------------
  // Одна круглая металлическая мишень на 50 м, малокалиберная винтовка:
  // лёжа — зона попадания 45 мм, стоя — 115 мм (IBU; biathlonworld.com,
  // deseret.com/2000/2/3/19489238). Попал = 10, мимо = 0; касание края
  // пулей — попадание (inward).
  static final TargetFace biathlonProne = TargetFace(
    code: 'biathlon_prone',
    name: /*tr*/ 'Биатлон: лёжа, 45 мм (50 м)',
    distanceM: 50,
    caliberMm: 5.6,
    // Чёрный круг для прицеливания 115 мм, поражение — только центральные
    // 45 мм (Правила биатлона РФ 2025, IBU ECR).
    bullseyeDiameterMm: 115,
    blankSizeMm: 150,
    ringDiametersMm: [45],
    integerScoring: true,
  );

  static final TargetFace biathlonStanding = TargetFace(
    code: 'biathlon_standing',
    name: /*tr*/ 'Биатлон: стоя, 115 мм (50 м)',
    distanceM: 50,
    caliberMm: 5.6,
    bullseyeDiameterMm: 115,
    blankSizeMm: 150,
    ringDiametersMm: [115],
    integerScoring: true,
  );

  // ---- Трап / скит ------------------------------------------------------
  // Геометрии мишени нет: тарелка ISSF диаметром 110 мм (±1) разбита или
  // нет (ISSF General Technical Rules, 6.x clay targets). Записывается как
  // «попал» (центр, 10) и «мимо» (за краем, 0) — см. [hitMiss].
  static final TargetFace clay = TargetFace(
    code: 'clay',
    name: /*tr*/ 'Трап / скит: тарелка 110 мм (попал/мимо)',
    distanceM: 20,
    caliberMm: 2.5,
    bullseyeDiameterMm: 110,
    blankSizeMm: 150,
    ringDiametersMm: [110],
    integerScoring: true,
  );

  // ---- IPSC ----------------------------------------------------------
  // Источник: IPSC Shotgun Competition Rules, Jan 2024, Appendix B2–B4
  // (чертежи с размерами в см). Очки — «Major»: A=5, C=4, D=2. Вокруг
  // мишени несчитаемая кромка (0.5 см; у Mini 0.3 см): попадание в неё — 0.
  // Угловые точки C у верхней кромки сняты с чертежа на глаз (±2 мм).
  // Дырка считается точкой (центр попадания), касание линии не учитывается.
  static TargetFace _ipsc({
    required String code,
    required String name,
    required double w,
    required double h,
    required List<List<double>> outer,
    required double border,
    required List<List<double>> c,
    required List<List<double>> a,
  }) {
    final out = ScoreZone.cm(0, outer, w, h);
    return TargetFace(
      code: code,
      name: name,
      distanceM: 10,
      caliberMm: 0,
      bullseyeDiameterMm: 0,
      blankSizeMm: (w > h ? w : h) * 10,
      ringDiametersMm: const [],
      integerScoring: true,
      outline: out,
      zones: [
        ScoreZone.cm(5, a, w, h),
        ScoreZone.cm(4, c, w, h),
        ScoreZone(2, out.inset(border * 10).poly),
      ],
    );
  }

  static final TargetFace ipsc = _ipsc(
    code: 'ipsc',
    name: /*tr*/ 'IPSC: стандартная мишень (45×57 см)',
    w: 45,
    h: 57,
    border: 0.5,
    outer: [[15, 0], [30, 0], [45, 19], [45, 38], [30, 57], [15, 57], [0, 38], [0, 19]],
    c: [[15.2, .5], [29.8, .5], [37.5, 19], [37.5, 33.5], [27.5, 45], [17.5, 45], [7.5, 33.5], [7.5, 19]],
    a: [[20, 2.5], [25, 2.5], [30, 19], [30, 27.5], [25, 35], [20, 35], [15, 27.5], [15, 19]],
  );

  static final TargetFace ipscMini = _ipsc(
    code: 'ipsc_mini',
    name: /*tr*/ 'IPSC: Mini (30×37.5 см)',
    w: 30,
    h: 37.5,
    border: 0.3,
    outer: [[10, 0], [20, 0], [30, 12.5], [30, 25], [20, 37.5], [10, 37.5], [0, 25], [0, 12.5]],
    c: [[11.5, .3], [18.5, .3], [25, 12.5], [25, 22], [18.5, 30], [11.5, 30], [5, 22], [5, 12.5]],
    a: [[13, 1.5], [17, 1.5], [20, 12.5], [20, 18], [17, 23], [13, 23], [10, 18], [10, 12.5]],
  );

  // Универсальная: размеры на чертеже даны от низа (v), здесь y = 75 − v.
  static final TargetFace ipscUniversal = _ipsc(
    code: 'ipsc_universal',
    name: /*tr*/ 'IPSC: Universal (45×75 см)',
    w: 45,
    h: 75,
    border: 0.5,
    outer: [[15, 0], [30, 0], [45, 19], [45, 38], [30, 75], [15, 75], [0, 38], [0, 19]],
    c: [[15.2, .5], [29.8, .5], [37.5, 21], [37.5, 33], [27.5, 58], [17.5, 58], [7.5, 33], [7.5, 21]],
    a: [[20, 2.5], [25, 2.5], [30, 22], [30, 30.5], [25, 43], [20, 43], [15, 30.5], [15, 22]],
  );

  static final List<TargetFace> all = [
    rifle10m,
    pistol10m,
    rifle50m,
    pistol25m,
    rifle300m,
    pistolRapid25m,
    moving50m,
    moving10m,
    archery122,
    archery80,
    archery80Six,
    archery60,
    archery60Compound,
    archery40,
    archery40Compound,
    archery40Triple,
    archery40TripleCompound,
    biathlonProne,
    biathlonStanding,
    clay,
    ipsc,
    ipscMini,
    ipscUniversal,
  ];

  /// Мишени для выбора в редакторах. Лук пока только в режиме разработчика;
  /// [keep] — уже выбранная мишень остаётся в списке всегда.
  static List<TargetFace> selectable({String? keep}) => [
        for (final f in all)
          if (!f.devOnly || friendlyErrorDevMode || f.code == keep) f
      ];

  static TargetFace byCode(String code) =>
      all.firstWhere((f) => f.code == code, orElse: () => rifle10m);
}
