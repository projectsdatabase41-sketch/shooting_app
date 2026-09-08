// Детект пробоин по фото (лог. слой, без камеры и без package:image —
// синтетические изображения строятся прямо в тесте).
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/shot_photo_detection.dart';

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
}
