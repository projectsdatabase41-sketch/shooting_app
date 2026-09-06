import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../logic/shot_photo_detection.dart';

class ShotPhotoException implements Exception {
  final String message;
  const ShotPhotoException(this.message);
  @override
  String toString() => message;
}

/// Мост между байтами фото (из `file_picker`, есть на всех платформах —
/// в отличие от `dart:io`, который в веб-сборку не компилируется) и
/// чистой логикой в `logic/shot_photo_detection.dart`.
///
/// Декодирование — единственное, для чего здесь нужен `package:image`;
/// сама логика поиска пробоин от него не зависит и тестируется без него
/// (синтетическими `GrayImage`, см. shot_photo_detection_test.dart).
class ShotPhotoService {
  /// Уменьшаем перед анализом: на реальных фото с телефона (несколько
  /// тысяч пикселей по стороне) box-blur и обход связных компонент на
  /// полном разрешении были бы заметно медленнее, а точность калибра
  /// (единицы мм) не требует больше пары тысяч пикселей на кадр.
  static const int maxWorkingSide = 1200;

  /// Декодирует байты — отдельно от анализа: экран калибровки показывает
  /// исходное фото (natural width/height нужны для раскладки), а декодировать
  /// дважды незачем.
  static img.Image decode(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const ShotPhotoException('Не удалось распознать файл как изображение');
    }
    return decoded;
  }

  /// Уменьшает уже декодированное фото до рабочего разрешения и переводит
  /// в градации серого для анализа.
  ///
  /// Возвращает и получившийся масштаб (во сколько раз уменьшили) —
  /// вызывающий код калибрует круг на ПОКАЗанном (исходном) фото и должен
  /// перевести пиксели калибровки в систему координат уменьшенной картинки
  /// этим же масштабом.
  static ({GrayImage image, double scale}) analyze(img.Image decoded) {
    final longSide = decoded.width > decoded.height ? decoded.width : decoded.height;
    final scale = longSide > maxWorkingSide ? maxWorkingSide / longSide : 1.0;
    final resized = scale == 1.0
        ? decoded
        : img.copyResize(
            decoded,
            width: (decoded.width * scale).round(),
            height: (decoded.height * scale).round(),
            interpolation: img.Interpolation.average,
          );
    // grayscale() уравнивает R=G=B=яркость — канал "red" после этого и
    // есть готовый одноканальный буфер яркости.
    final gray = img.grayscale(resized);
    final out = GrayImage(gray.width, gray.height, gray.getBytes(order: img.ChannelOrder.red));
    return (image: out, scale: scale);
  }
}
