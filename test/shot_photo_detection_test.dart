// Детект пробоин по фото (лог. слой, без камеры и без package:image —
// синтетические изображения строятся прямо в тесте).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/shot_photo_detection.dart';
import 'package:shooting_app/models/target_face.dart';

void main() {
  group('findCandidateHoles', () {
    test('пустая мишень — кандидатов нет', () {
      final img = GrayImage.filled(200, 200, 200);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('тёмная пробоина на светлом поле — находится в нужной точке', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(120, 80, 8, 40); // тёмный кружок, радиус ~ калибр
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, hasLength(1));
      expect(result.first.center.x, closeTo(120, 1.5));
      expect(result.first.center.y, closeTo(80, 1.5));
      expect(result.first.radiusPx, closeTo(8, 2));
    });

    test('светлая пробоина на тёмном яблоке — тоже находится (не только тёмные пятна)', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(100, 100, 60, 30); // тёмное яблоко
      img.fillCircle(105, 95, 8, 190); // пробоина светлее фона под ней
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, hasLength(1));
      expect(result.first.center.x, closeTo(105, 1.5));
      expect(result.first.center.y, closeTo(95, 1.5));
    });

    test('уже известная пробоина не предлагается повторно', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(120, 80, 8, 40);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
        knownHolesPx: const [PixelPoint(120, 80)],
      );
      expect(result, isEmpty);
    });

    test('пятно на месте печатной цифры габарита не предлагается как пробоина', () {
      const face = TargetFace.rifle10m;
      const center = PixelPoint(300, 300);
      const radiusPx = 250.0;
      const ring = 5;
      final outerMm = face.ringRadiiMm[10 - ring];
      final innerMm = face.ringRadiiMm[9 - ring];
      final midMm = (outerMm + innerMm) / 2;
      final labelR = midMm / face.faceRadiusMm * radiusPx;
      final labelX = center.x + labelR; // направление "вправо"

      final img = GrayImage.filled(600, 600, 210);
      img.fillCircle(labelX, center.y, 8, 40); // "цифра" — тёмное пятно на ожидаемом месте
      img.fillCircle(150, 450, 8, 40); // настоящая пробоина в стороне от подписей

      final result = findCandidateHoles(
        image: img,
        center: center,
        radiusPx: radiusPx,
        caliberRadiusPx: 8,
        ringRadiiMm: face.ringRadiiMm,
        faceRadiusMm: face.faceRadiusMm,
      );

      expect(result, hasLength(1));
      expect(result.first.center.x, closeTo(150, 1.5));
      expect(result.first.center.y, closeTo(450, 1.5));
    });

    test('пятно намного крупнее калибра отсеивается по размеру', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(100, 100, 40, 40); // радиус в разы больше калибра 8
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('вытянутая полоса (обрезок линии кольца) отсеивается по форме', () {
      final img = GrayImage.filled(200, 200, 210);
      for (var x = 60; x < 140; x++) {
        for (var y = 98; y < 102; y++) {
          img.set(x, y, 40); // тонкая горизонтальная полоса, не круг
        }
      }
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('две пробоины сразу — обе найдены раздельно', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(70, 70, 7, 45);
      img.fillCircle(130, 130, 7, 45);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 7,
      );
      expect(result, hasLength(2));
      final xs = result.map((c) => c.center.x).toList()..sort();
      expect(xs.first, closeTo(70, 1.5));
      expect(xs.last, closeTo(130, 1.5));
    });

    test('пустая мишень с напечатанными кольцами — пробоин быть не должно', () {
      // Реальная находка пользователя: мишень с чёткой печатной разметкой
      // (толстые концентричные кольца) без единой настоящей пробоины
      // алгоритм заполнял ложными "пробоинами" ровно там, где кольцо
      // проходит через горизонтальную/вертикальную ось — в этих точках
      // локальный изгиб кольца на маленьком окне анализа выглядит почти
      // как компактное пятно, а не длинная дуга.
      final img = GrayImage.filled(400, 400, 220);
      img.fillCircle(200, 200, 190, 20); // тёмное яблоко в центре
      for (final r in <double>[20, 40, 60, 80, 100, 120, 140, 160, 180]) {
        img.fillRing(200, 200, r, 6, 20);
      }
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(200, 200),
        radiusPx: 190,
        caliberRadiusPx: 6,
      );
      expect(result, isEmpty, reason: 'напечатанные кольца не должны приниматься за пробоины');
    });

    test('вне откалиброванного круга не ищем', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(10, 10, 7, 40); // далеко за пределами radiusPx от центра
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 50,
        caliberRadiusPx: 7,
      );
      expect(result, isEmpty);
    });
  });

  group('detectTargetCircle', () {
    test('светлый бланк по центру тёмного фона — найден верно', () {
      final img = GrayImage.filled(300, 300, 40);
      img.fillCircle(150, 150, 100, 210);
      final result = detectTargetCircle(img);
      expect(result, isNotNull);
      expect(result!.center.x, closeTo(150, 3));
      expect(result.center.y, closeTo(150, 3));
      expect(result.radiusPx, closeTo(100, 4));
    });

    test('бланк смещён от центра кадра — центр найден по самому бланку', () {
      final img = GrayImage.filled(300, 300, 210);
      img.fillCircle(100, 180, 80, 30);
      final result = detectTargetCircle(img);
      expect(result, isNotNull);
      expect(result!.center.x, closeTo(100, 3));
      expect(result.center.y, closeTo(180, 3));
    });

    test('тёмное яблоко в центре не должно останавливать разлив раньше внешнего края бланка', () {
      // Реальная находка пользователя: связный разлив от центра
      // застревал на границе чёрного яблока (сильный контраст с
      // фоном), хотя настоящий край бланка — заметно дальше, просто
      // белое кольцо между ними от фона кадра не отличить по цвету.
      // Итоговый радиус получался в разы меньше настоящего, и всё,
      // что ищет пробоины дальше, калибровалось на крошечный "калибр".
      final img = GrayImage.filled(400, 400, 220); // фон
      img.fillCircle(200, 200, 40, 20); // яблоко — маленькое и тёмное
      // между яблоком и настоящим краем — просто фон (белое поле)
      img.fillRing(200, 200, 150, 4, 20); // тонкая внешняя граница бланка
      final result = detectTargetCircle(img);
      expect(result, isNotNull);
      expect(result!.center.x, closeTo(200, 3));
      expect(result.center.y, closeTo(200, 3));
      expect(result.radiusPx, closeTo(150, 6), reason: 'радиус должен доходить до внешней границы, а не до яблока');
    });

    test('мишень занимает весь кадр без видимого фона — радиус берётся из известной геометрии яблока', () {
      // То же яблоко без фона, что и в предыдущем тесте, но фона вокруг
      // НЕТ вовсе (только яблоко в центре кадра) — лучи не находят
      // ничего дальше яблока, и без geometрии мишени радиус остался бы
      // радиусом яблока. Отношение 3.0 — как если бы у выбранного
      // упражнения faceRadiusMm втрое больше bullseyeRadiusMm.
      final img = GrayImage.filled(400, 400, 220);
      img.fillCircle(200, 200, 50, 20);
      final result = detectTargetCircle(img, bullseyeToFaceRatio: 3.0);
      expect(result, isNotNull);
      expect(result!.radiusPx, closeTo(150, 10), reason: '50 (яблоко) × 3.0 = 150 (вся мишень)');
    });

    test('без переданного отношения и без видимого фона — остаётся радиус яблока (как раньше)', () {
      final img = GrayImage.filled(400, 400, 220);
      img.fillCircle(200, 200, 50, 20);
      final result = detectTargetCircle(img);
      expect(result, isNotNull);
      expect(result!.radiusPx, closeTo(50, 3));
    });

    test('лист бумаги крупнее печатной мишени (поля с заметками рядом) — доверяем яблоку, не краю листа', () {
      // Реальная находка пользователя: мишень напечатана на листе с
      // большими полями (там же — дописанные от руки вычисления),
      // лист заметно крупнее и не по центру самой мишени. Разлив-от-фона
      // и лучи в этом случае цепляют край ВСЕГО ЛИСТА (белый лист
      // хорошо отличим от тёмного фона стола), а не круг мишени —
      // радиус и центр получаются неверными. Проверка по яблоку должна
      // это заметить и не довериться такому результату.
      final img = GrayImage.filled(500, 600, 60); // тёмный "стол"
      // Лист бумаги — шире и выше самой мишени (поля с заметками снизу).
      // Мишень наводится камерой примерно в центр КАДРА, как в жизни —
      // лишние поля листа выходят за его пределы неравномерно, а не
      // сдвигают саму мишень далеко от центра кадра.
      for (var y = 20; y < 580; y++) {
        for (var x = 40; x < 460; x++) {
          img.set(x, y, 210);
        }
      }
      img.fillCircle(250, 260, 60, 20);
      final result = detectTargetCircle(img, bullseyeToFaceRatio: 2.5);
      expect(result, isNotNull);
      expect(result!.center.x, closeTo(250, 15));
      expect(result.center.y, closeTo(260, 15), reason: 'центр мишени, а не центр всего листа бумаги');
      expect(result.radiusPx, closeTo(150, 20), reason: '60 (яблоко) × 2.5 = 150, а не радиус листа');
    });

    test('фон и центр кадра почти одного цвета — не с чем сравнивать', () {
      final img = GrayImage.filled(300, 300, 200);
      final result = detectTargetCircle(img);
      expect(result, isNull);
    });

    test('бланк заполняет весь кадр (фон виден лишь в уголках) — граница не найдена', () {
      final img = GrayImage.filled(300, 300, 210);
      // Фон-подсказка только в самых уголках — угадать границу бланка
      // по такому кадру нельзя, область расползается до всех краёв.
      for (final corner in [(0, 0), (288, 0), (0, 288), (288, 288)]) {
        img.fillCircle(corner.$1 + 6, corner.$2 + 6, 6, 40);
      }
      final result = detectTargetCircle(img);
      expect(result, isNull);
    });

    test('слишком маленький кадр отклоняется сразу', () {
      final img = GrayImage.filled(10, 10, 210);
      expect(detectTargetCircle(img), isNull);
    });

    test('настоящий круг (снят строго анфас) — radiusYPx ≈ radiusPx, овал не выдумывается', () {
      final img = GrayImage.filled(300, 300, 40);
      img.fillCircle(150, 150, 100, 210);
      final result = detectTargetCircle(img)!;
      expect(result.radiusYPx, closeTo(result.radiusPx, result.radiusPx * 0.08));
    });

    test('фото под углом — печатное кольцо на кадре овал: radiusYPx заметно меньше radiusPx', () {
      // Полуось a=120 вдоль угла 30°, полуось b=80 поперёк — как круглая
      // мишень, снятая не строго анфас (перспективное сжатие по одной оси).
      const cx = 200.0, cy = 200.0, a = 120.0, b = 80.0, angleDeg = 30.0;
      const angle = angleDeg * 3.14159265 / 180;
      final cosA = math.cos(angle), sinA = math.sin(angle);
      final img = GrayImage.filled(400, 400, 40);
      for (var y = 0; y < 400; y++) {
        for (var x = 0; x < 400; x++) {
          final dx = x - cx, dy = y - cy;
          final u = dx * cosA + dy * sinA; // вдоль большой полуоси
          final v = -dx * sinA + dy * cosA; // поперёк
          if ((u * u) / (a * a) + (v * v) / (b * b) <= 1) img.set(x, y, 210);
        }
      }
      final result = detectTargetCircle(img)!;
      // radiusX/radiusY у эллипса из подгонки могут поменяться местами с
      // углом (radiusX всегда "вдоль angleRad", а какая из осей отдана в
      // radiusX — большая или меньшая — не важно: (rx,ry,φ) и (ry,rx,φ+90°)
      // задают тот же самый эллипс, дальше по коду используются вместе).
      // Проверяем сам ЭЛЛИПС: обе полуоси найдены верно, овальность
      // выражена, а radiusX действительно измерена именно под тем углом,
      // что вернула функция.
      final axes = [result.radiusPx, result.radiusYPx]..sort();
      expect(axes[0], closeTo(b, b * 0.15), reason: 'меньшая полуось');
      expect(axes[1], closeTo(a, a * 0.15), reason: 'большая полуось');
      expect(result.radiusYPx, isNot(closeTo(result.radiusPx, result.radiusPx * 0.1)), reason: 'явно не круг');
      // Истинный радиус мишени под углом angleRad — сверяем с formula
      // эллипса (a=120 по 30°, b=80 поперёк), а не гадаем, какая полуось
      // считается "первой".
      const trueAngle = angleDeg * 3.14159265 / 180;
      final d = result.angleRad - trueAngle;
      final expectedAtAngle =
          (a * b) / math.sqrt(math.pow(b * math.cos(d), 2) + math.pow(a * math.sin(d), 2));
      expect(result.radiusPx, closeTo(expectedAtAngle, expectedAtAngle * 0.15));
    });
  });

  group('refineRadiusByRings', () {
    // Настоящая геометрия мишени № 7 (50 м) — те же пропорции колец,
    // что и в реальном бланке, отрисованные тонкими линиями (не
    // сплошными кольцами) на известном масштабе.
    const face = TargetFace.rifle50m;
    const truePx = 200.0;

    GrayImage drawRings(double scalePx) {
      final img = GrayImage.filled(500, 500, 210);
      for (final ringMm in face.ringRadiiMm) {
        img.fillRing(250, 250, ringMm / face.faceRadiusMm * scalePx, 2, 40);
      }
      return img;
    }

    test('исправляет масштаб, если начальная оценка радиуса заметно мимо', () {
      final img = drawRings(truePx);
      final refined = refineRadiusByRings(
        image: img,
        center: const PixelPoint(250, 250),
        initialRadiusPx: truePx * 0.7, // на 30% занижена
        ringRadiiMm: face.ringRadiiMm,
        faceRadiusMm: face.faceRadiusMm,
      );
      expect(refined, closeTo(truePx, 6));
    });

    test('не портит уже верную оценку радиуса', () {
      final img = drawRings(truePx);
      final refined = refineRadiusByRings(
        image: img,
        center: const PixelPoint(250, 250),
        initialRadiusPx: truePx,
        ringRadiiMm: face.ringRadiiMm,
        faceRadiusMm: face.faceRadiusMm,
      );
      expect(refined, closeTo(truePx, 6));
    });
  });

  group('pixelToMm', () {
    test('центр остаётся центром', () {
      final mm = pixelToMm(const PixelPoint(100, 100), const PixelPoint(100, 100), 90, 40);
      expect(mm.x, closeTo(0, 1e-9));
      expect(mm.y, closeTo(0, 1e-9));
    });

    test('вправо по пикселям = вправо по мм, вверх по пикселям = вверх по мм (Y инвертируется)', () {
      // Пиксель правее центра -> +X мм. Пиксель ВЫШЕ центра (меньший y)
      // -> +Y мм: та же конвенция, что и на экране мишени.
      final right = pixelToMm(const PixelPoint(190, 100), const PixelPoint(100, 100), 90, 45);
      expect(right.x, closeTo(45, 1e-6));
      expect(right.y, closeTo(0, 1e-6));

      final up = pixelToMm(const PixelPoint(100, 10), const PixelPoint(100, 100), 90, 45);
      expect(up.x, closeTo(0, 1e-6));
      expect(up.y, closeTo(45, 1e-6));
    });
  });

  group('pixelToMmEllipse / mmToPixelEllipse — калибровка под углом', () {
    test('без поворота и с равными полуосями совпадает с pixelToMm', () {
      const center = PixelPoint(100, 100);
      const px = PixelPoint(160, 40);
      final circle = pixelToMm(px, center, 90, 45);
      final ellipse = pixelToMmEllipse(px, center, 90, 90, 0, 45);
      expect(ellipse.x, closeTo(circle.x, 1e-9));
      expect(ellipse.y, closeTo(circle.y, 1e-9));
    });

    test('mmToPixelEllipse — точное обращение pixelToMmEllipse при повороте и разных полуосях', () {
      const center = PixelPoint(200, 150);
      const px = PixelPoint(260, 90);
      const rx = 90.0, ry = 60.0, angle = 0.4;
      final mm = pixelToMmEllipse(px, center, rx, ry, angle, 45);
      final back = mmToPixelEllipse(mm, center, rx, ry, angle, 45);
      expect(back.x, closeTo(px.x, 1e-6));
      expect(back.y, closeTo(px.y, 1e-6));
    });
  });
}
