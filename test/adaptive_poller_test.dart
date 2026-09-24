import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/adaptive_poller.dart';

const fast = Duration(milliseconds: 100);
const slow = Duration(seconds: 3);

void main() {
  group('AdaptivePoller — интервал', () {
    test('в покое интервал растёт ×1.5 до максимума, новое возвращает минимум', () {
      final p = AdaptivePoller(min: const Duration(seconds: 5), max: const Duration(seconds: 60));
      expect(p.interval, const Duration(seconds: 5));
      var last = p.interval;
      for (var i = 0; i < 20; i++) {
        p.onResult(latency: fast, ok: true, gotNew: false);
        expect(p.interval >= last, isTrue);
        last = p.interval;
      }
      expect(p.interval, const Duration(seconds: 60));
      p.onResult(latency: fast, ok: true, gotNew: true);
      expect(p.interval, const Duration(seconds: 5));
    });

    test('медленный ответ или ошибка удваивают нагрузку, быстрые — плавно снижают', () {
      final p = AdaptivePoller(min: const Duration(seconds: 5), max: const Duration(seconds: 60));
      p.onResult(latency: slow, ok: true, gotNew: true);
      expect(p.load, 2);
      expect(p.interval, const Duration(seconds: 10));
      p.onResult(latency: fast, ok: false, gotNew: true);
      expect(p.load, 4);
      for (var i = 0; i < 40; i++) {
        p.onResult(latency: slow, ok: true, gotNew: true);
      }
      expect(p.load, AdaptivePoller.maxLoad);
      // Снижение — по 0.25 за быстрый ответ, а не скачком.
      p.onResult(latency: fast, ok: true, gotNew: true);
      expect(p.load, AdaptivePoller.maxLoad - 0.25);
      for (var i = 0; i < 100; i++) {
        p.onResult(latency: fast, ok: true, gotNew: true);
      }
      expect(p.load, 1);
    });

    test('удалённый рычаг scale замедляет всех и ограничен разумными пределами', () {
      var scale = 3.0;
      final p = AdaptivePoller(min: const Duration(seconds: 5), max: const Duration(seconds: 60), scale: () => scale);
      expect(p.interval, const Duration(seconds: 15));
      scale = 1000;
      expect(p.interval, const Duration(seconds: 100)); // не больше ×20
      scale = 0;
      expect(p.interval, const Duration(milliseconds: 1250)); // не меньше ×0.25
    });

    test('nudge возвращает частый режим', () {
      final p = AdaptivePoller(min: const Duration(seconds: 5), max: const Duration(seconds: 60));
      for (var i = 0; i < 10; i++) {
        p.onResult(latency: fast, ok: true, gotNew: false);
      }
      expect(p.interval > const Duration(seconds: 5), isTrue);
      p.nudge();
      expect(p.interval, const Duration(seconds: 5));
    });
  });

  group('PollLoop', () {
    AdaptivePoller tiny() => AdaptivePoller(min: const Duration(milliseconds: 20), max: const Duration(milliseconds: 40));

    test('опрашивает по кругу и не накладывает запросы друг на друга', () async {
      var running = 0;
      var maxParallel = 0;
      var ticks = 0;
      final loop = PollLoop(
        poller: tiny(),
        tick: () async {
          running++;
          maxParallel = running > maxParallel ? running : maxParallel;
          ticks++;
          await Future<void>.delayed(const Duration(milliseconds: 60)); // дольше интервала
          running--;
          return false;
        },
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      loop.stop();
      expect(ticks, greaterThan(2));
      expect(maxParallel, 1);
    });

    test('poke опрашивает сразу; stop останавливает; исключение цикл не убивает', () async {
      var ticks = 0;
      final loop = PollLoop(
        poller: AdaptivePoller(min: const Duration(seconds: 30), max: const Duration(seconds: 60)),
        tick: () async {
          ticks++;
          if (ticks == 1) throw Exception('сеть');
          return true;
        },
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, 0); // интервал 30 с — сам ещё не сработал
      loop.poke();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, 1); // поймали исключение, но цикл жив
      expect(loop.isRunning, isTrue);
      loop.poke();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, 2);
      loop.stop();
      loop.poke();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, 2); // после stop poke ничего не делает
      expect(loop.isRunning, isFalse);
    });

    test('после ошибки нагрузка растёт (защита базы)', () async {
      final poller = tiny();
      final loop = PollLoop(poller: poller, tick: () async => throw Exception('500'))..start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      loop.stop();
      expect(poller.load, greaterThan(1));
    });
  });
}
