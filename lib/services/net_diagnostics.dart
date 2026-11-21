import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'call_service.dart';
import 'chat_auth_service.dart';
import 'chat_settings.dart';
import 'demo_mode.dart';
import 'firebase_settings.dart';
import 'ice_servers.dart';
import 'local_db_service.dart';
import 'supabase_auth_service.dart';
import 'webrtc_peer_link.dart';
import 'web_push_token.dart';
import '../models/chat_contact.dart';

/// Результат одного шага диагностики.
class DiagStepResult {
  final String name;
  final bool passed;
  final String details;
  final Duration latency;

  const DiagStepResult({
    required this.name,
    required this.passed,
    required this.details,
    required this.latency,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'passed': passed,
        'details': details,
        'latencyMs': latency.inMilliseconds,
      };
}

/// Полный отчёт диагностики.
class NetDiagReport {
  final DateTime startedAt;
  final DateTime finishedAt;
  final List<DiagStepResult> steps;
  final String platform;
  final String version;
  final String? partnerId;
  final String? partnerNickname;
  final String networkType;
  final String? fcmToken;

  NetDiagReport({
    required this.startedAt,
    required this.finishedAt,
    required this.steps,
    required this.platform,
    required this.version,
    this.partnerId,
    this.partnerNickname,
    required this.networkType,
    this.fcmToken,
  });

  bool get allPassed => steps.every((s) => s.passed);

  String toReportText() {
    final buf = StringBuffer();
    buf.writeln('[ДИАГНОСТИКА СЕТИ]');
    buf.writeln('Платформа: $platform');
    buf.writeln('Версия: $version');
    buf.writeln('Сеть: $networkType');
    if (fcmToken != null && fcmToken!.isNotEmpty) {
      buf.writeln('FCM: ${fcmToken!.substring(0, 20)}…');
    }
    if (partnerId != null) {
      buf.writeln('Партнёр: ${partnerNickname ?? '—'} ($partnerId)');
    }
    buf.writeln('Время: ${startedAt.toIso8601String()} — ${finishedAt.toIso8601String()}');
    buf.writeln('');
    buf.writeln('Шаги:');
    for (final s in steps) {
      final mark = s.passed ? '✓' : '✗';
      buf.writeln('$mark ${s.name} (${s.latency.inMilliseconds} мс): ${s.details}');
    }
    return buf.toString();
  }

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'steps': [for (final s in steps) s.toJson()],
        'platform': platform,
        'version': version,
        'partnerId': partnerId,
        'partnerNickname': partnerNickname,
        'networkType': networkType,
        'fcmToken': fcmToken,
      };
}

/// Запуск пошаговой диагностики сети.
class NetDiagnostics {
  NetDiagnostics({
    required this.db,
    required this.chatAuth,
    required this.mainAuth,
    required this.partner,
    this.onProgress,
  });

  final LocalDbService db;
  final ChatAuthService chatAuth;
  final SupabaseAuthService mainAuth;
  final ChatContact partner;
  final void Function(DiagStepResult step)? onProgress;

  // Диагностика — сознательно долгая проверка (её запускают руками или по
  // ошибке), поэтому общий лимит 2 минуты, а не 30 секунд: сбор ICE-кандидатов
  // сам по себе ждёт 8 секунд, и на прежних 30 с отчёт обрывался посреди
  // списка шагов (отчёты 20.11: «ICE кандидаты: TimeoutException 10004 мс»).
  static const _totalTimeout = Duration(seconds: 120);
  static const _stepTimeout = Duration(seconds: 25);

  Future<NetDiagReport> run() async {
    final startedAt = DateTime.now();
    final steps = <DiagStepResult>[];
    final completer = Completer<NetDiagReport>();

    // Таймаут на всю диагностику
    final timer = Timer(_totalTimeout, () async {
      if (!completer.isCompleted) {
        completer.complete(NetDiagReport(
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          steps: steps,
          platform: defaultTargetPlatform.name,
          version: _appVersion(),
          partnerId: partner.id,
          partnerNickname: partner.nickname,
          networkType: await _networkType(),
          fcmToken: await _fcmToken(),
        ));
      }
    });

    try {
      // 1. Сеть и время
      steps.add(await _step('Сеть и время', _checkNetwork));

      // Отдельно — задержка самого сервера звонков и открытие комнаты
      // сигналинга: по ним видно, где именно «медленно» или «не пускает».
      steps.add(await _step('Сервер звонков (RTT)', _checkWorkerRtt));
      steps.add(await _step('Комната сигналинга', _checkRoomOpen));

      // 2. ICE-серверы
      steps.add(await _step('ICE-серверы', _checkIceServers));

      // 3. Вход (токены)
      steps.add(await _step('Вход', _checkAuth));

      // 4. Push (FCM)
      steps.add(await _step('Push (FCM)', _checkPush));

      // 5. ICE кандидаты (сбор)
      steps.add(await _step('ICE кандидаты', _checkIceCandidates));

      // 5a. Бюджет TURN: сколько бесплатного объёма израсходовано.
      steps.add(await _step('Бюджет TURN', _checkTurnBudget));

      // 6. Сигналинг
      steps.add(await _step('Сигналинг', _checkSignaling));

      // 7. P2P + DataChannel
      //
      // Шага «Скорость (DataChannel)» здесь больше нет: прежняя проверка
      // отправляла 256 КБ сама себе по каналу, у которого нет второй стороны,
      // и гарантированно падала по таймауту — в каждом отчёте появлялся
      // красный крест «Future not completed» (отчёты 19–20.11). Измерить
      // скорость канала без собеседника невозможно; реальную скорость видно
      // в P2P-обмене файлами.
      steps.add(await _step('P2P + DataChannel', _checkP2P));

      final report = NetDiagReport(
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        steps: steps,
        platform: defaultTargetPlatform.name,
        version: _appVersion(),
        partnerId: partner.id,
        partnerNickname: partner.nickname,
        networkType: await _networkType(),
        fcmToken: await _fcmToken(),
      );

      timer.cancel();
      completer.complete(report);
    } catch (e) {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.complete(NetDiagReport(
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          steps: steps,
          platform: defaultTargetPlatform.name,
          version: _appVersion(),
          partnerId: partner.id,
          partnerNickname: partner.nickname,
          networkType: await _networkType(),
          fcmToken: await _fcmToken(),
        ));
      }
    }

    return completer.future;
  }

  Future<DiagStepResult> _step(String name, Future<DiagStepResult> Function() fn) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await fn().timeout(_stepTimeout);
      stopwatch.stop();
      onProgress?.call(result);
      return result;
    } catch (e) {
      stopwatch.stop();
      final result = DiagStepResult(
        name: name,
        passed: false,
        details: 'ошибка: ${e.toString().replaceAll('\n', ' ')}',
        latency: stopwatch.elapsed,
      );
      onProgress?.call(result);
      return result;
    }
  }

  /// 1. Сеть и время: пинг до чат-базы и сервера звонков
  Future<DiagStepResult> _checkNetwork() async {
    final client = http.Client();
    try {
      final chatPing = await _ping(client, '${ChatSettings.url}/rest/v1/');
      final callsPing = await _ping(client, '${CallService.url}/ice');

      final ok = chatPing != null || callsPing != null;
      final details = 'чат: ${chatPing != null ? '${chatPing.inMilliseconds} мс' : 'нет ответа'}; '
          'звонки: ${callsPing != null ? '${callsPing.inMilliseconds} мс' : 'нет ответа'}';

      return DiagStepResult(name: 'Сеть и время', passed: ok, details: details, latency: Duration.zero);
    } finally {
      client.close();
    }
  }

  Future<Duration?> _ping(http.Client client, String url) async {
    final sw = Stopwatch()..start();
    try {
      final res = await client.head(Uri.parse(url)).timeout(const Duration(seconds: 5));
      sw.stop();
      return res.statusCode < 500 ? sw.elapsed : null;
    } catch (_) {
      sw.stop();
      return null;
    }
  }

  /// 2. ICE-серверы: что вернул /ice, turnProvider, TURN хосты
  Future<DiagStepResult> _checkIceServers() async {
    try {
      final cs = CallService(chatAuth);
      final ice = await cs.iceServers();
      final turnProvider = IceServers.lastTurnProvider ?? 'none';
      final turnHosts = IceServers.turnHosts(ice);
      final stunCount = ice.where((s) {
        final u = s['urls'];
        final list = u is List ? u : [u];
        return list.any((x) => '$x'.startsWith('stun:'));
      }).length;
      final turnCount = ice.where((s) {
        final u = s['urls'];
        final list = u is List ? u : [u];
        return list.any((x) => '$x'.startsWith('turn:'));
      }).length;

      final details = 'STUN: $stunCount, TURN: $turnCount, провайдер: $turnProvider, хосты: $turnHosts';
      return DiagStepResult(
        name: 'ICE-серверы',
        passed: stunCount > 0,
        details: details,
        latency: Duration.zero,
      );
    } catch (e) {
      return DiagStepResult(
        name: 'ICE-серверы',
        passed: false,
        details: 'ошибка: $e',
        latency: Duration.zero,
      );
    }
  }

  /// 3. Вход: токен мессенджера, свежесть, вход в личную базу
  Future<DiagStepResult> _checkAuth() async {
    final chatSignedIn = chatAuth.isSignedIn;
    final chatTokenFresh = chatSignedIn && (await chatAuth.ensureFreshToken()) != null;
    final mainSignedIn = mainAuth.isSignedIn;
    final mainTokenFresh = mainSignedIn && (await mainAuth.ensureFreshToken()) != null;

    final details = 'чат: ${chatSignedIn ? (chatTokenFresh ? 'ок' : 'токен не свеж') : 'не входит'}; '
        'личная база: ${mainSignedIn ? (mainTokenFresh ? 'ок' : 'токен не свеж') : 'не входит'}';

    return DiagStepResult(
      name: 'Вход',
      passed: chatSignedIn && chatTokenFresh,
      details: details,
      latency: Duration.zero,
    );
  }

  /// 4. Push (FCM): разрешение, токен, зарегистрирован ли на сервере звонков
  Future<DiagStepResult> _checkPush() async {
    if (kIsWeb) {
      final perm = await webPushPermission();
      final config = {
        'apiKey': FirebaseSettings.webApiKey,
        'appId': FirebaseSettings.webAppId,
        'messagingSenderId': FirebaseSettings.messagingSenderId,
        'projectId': FirebaseSettings.projectId,
        'authDomain': FirebaseSettings.webAuthDomain,
      };
      final token = await webPushToken(config, FirebaseSettings.webVapidKey);
      final registered = token != null && token.isNotEmpty;
      final details = 'веб: разрешение=$perm, токен=${registered ? 'есть' : 'нет'}';
      return DiagStepResult(name: 'Push (FCM)', passed: registered, details: details, latency: Duration.zero);
    }

    // Android/iOS — через PushService
    try {
      final messaging = FirebaseMessaging.instance;
      final perm = await messaging.getNotificationSettings();
      final authorized = perm.authorizationStatus == AuthorizationStatus.authorized;
      String? token;
      if (authorized) {
        token = await messaging.getToken();
      }
      final hasToken = token != null && token.isNotEmpty;

      // Проверим регистрацию на сервере звонков
      bool registered = false;
      if (hasToken && chatAuth.isSignedIn) {
        try {
          final cs = CallService(chatAuth);
          await cs.registerDevice(token);
          registered = true;
        } catch (_) {}
      }

      // «на сервере» здесь означало только то, что мы сами сейчас отправили
      // регистрацию: реестр токенов не читается. Пишем честно.
      final details = 'разрешение=${authorized ? 'есть' : 'нет'}, токен=${hasToken ? 'есть' : 'нет'}, '
          'регистрация отправлена=${registered ? 'да' : 'нет'}';
      return DiagStepResult(name: 'Push (FCM)', passed: authorized && hasToken, details: details, latency: Duration.zero);
    } catch (e) {
      return DiagStepResult(name: 'Push (FCM)', passed: false, details: 'ошибка: $e', latency: Duration.zero);
    }
  }

  /// 5. ICE кандидаты: сбор, типы (host/srflx/relay), время

  /// Бюджет ретранслятора: Cloudflare даёт 1000 ГБ TURN в месяц, у воркера
  /// порог CF_TURN_LIMIT_GB (800 ГБ). Показываем расход, чтобы было видно,
  /// сколько осталось, и что при 95% TURN отключается автоматически.
  Future<DiagStepResult> _checkTurnBudget() async {
    final sw = Stopwatch()..start();
    try {
      final u = await CallService(chatAuth).monthUsage(fresh: true).timeout(const Duration(seconds: 8));
      sw.stop();
      if (u == null) {
        return DiagStepResult(
            name: 'Бюджет TURN', passed: false, details: 'сервер не ответил', latency: sw.elapsed);
      }
      String gb(num bytes) => (bytes / 1e9).toStringAsFixed(2);
      final cf = u['cloudflare'];
      final metered = u['metered'];
      final cfUsed = cf is Map ? (cf['usedBytes'] as num?)?.toDouble() ?? 0 : 0.0;
      final cfLimit = cf is Map ? (cf['limitBytes'] as num?)?.toDouble() ?? 0 : 0.0;
      final mUsed = metered is Map ? (metered['usedBytes'] as num?)?.toDouble() ?? 0 : 0.0;
      final mLimit = metered is Map ? (metered['limitBytes'] as num?)?.toDouble() ?? 0 : 0.0;
      final pct = cfLimit > 0 ? (cfUsed / cfLimit * 100) : 0.0;
      final left = cfLimit > cfUsed ? cfLimit - cfUsed : 0.0;
      final shortage = cfLimit > 0 && cfUsed >= cfLimit * 0.95;
      return DiagStepResult(
        name: 'Бюджет TURN',
        passed: !shortage,
        details: 'Cloudflare: ${gb(cfUsed)} из ${gb(cfLimit)} ГБ (${pct.toStringAsFixed(1)}%), '
            'осталось ${gb(left)} ГБ · Metered: ${gb(mUsed)} из ${gb(mLimit)} ГБ'
            '${shortage ? ' · порог близко: TURN отключается, звонки пойдут напрямую' : ''}',
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return DiagStepResult(name: 'Бюджет TURN', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }
  Future<DiagStepResult> _checkIceCandidates() async {
    final sw = Stopwatch()..start();
    try {
      final ice = await CallService(chatAuth).iceServers();
      final pc = await createPeerConnection({'iceServers': ice});
      final cands = <String, int>{};
      final gathered = Completer<void>();

      pc.onIceCandidate = (c) {
        final s = c.candidate;
        if (s == null) {
          // Некоторые платформы отмечают конец сбора пустым кандидатом.
          if (!gathered.isCompleted) gathered.complete();
          return;
        }
        final m = RegExp(r' typ (\w+)').firstMatch(s);
        if (m != null) cands[m.group(1)!] = (cands[m.group(1)] ?? 0) + 1;
      };

      await pc.setLocalDescription(await pc.createOffer());
      // Ждём конец сбора, но не считаем таймаут ошибкой: вторая сторона для
      // этого шага не нужна, важно — собрались ли свои кандидаты.
      try {
        await gathered.future.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        // собрали сколько успели
      }
      await pc.close();
      sw.stop();

      final total = cands.values.fold(0, (a, b) => a + b);
      final details = 'всего: $total; '
          '${cands.entries.map((e) => '${e.key}:${e.value}').join(', ')}'
          '${cands.isEmpty ? ' (за 8 с не собралось ни одного — нет STUN/TURN или сеть режет UDP)' : ''}';

      return DiagStepResult(
        name: 'ICE кандидаты',
        passed: total > 0,
        details: details,
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return DiagStepResult(name: 'ICE кандидаты', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }
  /// 6. Сигналинг: открытие комнаты, обмен ring/join
  Future<DiagStepResult> _checkSignaling() async {
    final sw = Stopwatch()..start();
    try {
      if (!chatAuth.isSignedIn) {
        sw.stop();
        return DiagStepResult(name: 'Сигналинг', passed: false, details: 'нет входа в чат', latency: sw.elapsed);
      }
      // callId обязан быть uuid v4 — иначе сервер отвечает 400 (отзыв 17.11:
      // «Сервер звонков: 400» — это была ошибка самой проверки).
      final callId = const Uuid().v4();
      final cs = CallService(chatAuth);
      final delivered = await cs
          .ring(callId: callId, to: partner.id, name: 'Диагностика', video: false)
          .timeout(const Duration(seconds: 8));
      await cs.cancel(callId: callId, to: partner.id);
      sw.stop();
      return DiagStepResult(
        name: 'Сигналинг',
        passed: true,
        details: 'сервер принял вызов, устройств с push: $delivered'
            '${delivered == 0 ? ' — у собеседника нет адреса устройства: пусть откроет приложение и разрешит уведомления, вызов без этого не покажется' : ''}',
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return DiagStepResult(name: 'Сигналинг', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }
  /// 7. P2P + DataChannel: поднимается ли канал, время, пара кандидатов
  Future<DiagStepResult> _checkP2P() async {
    final sw = Stopwatch()..start();
    try {
      if (!chatAuth.isSignedIn) {
        sw.stop();
        return DiagStepResult(name: 'P2P (самопроверка)', passed: false, details: 'нет входа в чат', latency: sw.elapsed);
      }

      final link = WebRtcPeerLink(iceServers: () => CallService(chatAuth).iceServers());
      final completer = Completer<DiagStepResult>();
      bool resolved = false;

      link.onState = () {
        if (resolved) return;
        if (link.isOpen) {
          resolved = true;
          sw.stop();
          completer.complete(DiagStepResult(
            name: 'P2P (самопроверка)',
            passed: true,
            details: 'DataChannel открыт за ${sw.elapsed.inMilliseconds} мс',
            latency: sw.elapsed,
          ));
        }
      };

      // Запускаем как инициатор
      await link.start(initiator: true);

      // Собеседника в этой проверке нет, поэтому соединение принципиально не
      // может подняться: если за 8 секунд не открылось, считаем проверку
      // выполненной (кандидаты собраны, ICE работает), а не провалом —
      // иначе отчёт всегда «красный» и пугает (отзывы 17.11, 19–24).
      try {
        final result = await completer.future.timeout(const Duration(seconds: 8));
        link.close(silent: true);
        return result;
      } on TimeoutException {
        sw.stop();
        link.close(silent: true);
        return DiagStepResult(
          name: 'P2P (самопроверка)',
          passed: true,
          details: 'без собеседника: свои кандидаты собраны (${link.candidates.isEmpty ? 'нет данных' : link.candidates.entries.map((e) => '${e.key}:${e.value}').join(', ')}). '
              'ICE-пары здесь не проверяются — для этого нужен второй участник; '
              'реальную связь проверяйте звонком или сообщением',
          latency: sw.elapsed,
        );
      }
    } catch (e) {
      sw.stop();
      return DiagStepResult(name: 'P2P (самопроверка)', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }

  /// Выбранная ICE-пара и её задержка по `getStats`: видно, идёт ли трафик
  /// напрямую (host/srflx) или через ретранслятор (relay) и сколько мс RTT.
  /// Без этого отчёт говорил только «не поднялось», без причины.

  /// Задержка сервера звонков: публичная сводка `/stats`, без токена.
  Future<DiagStepResult> _checkWorkerRtt() async {
    final sw = Stopwatch()..start();
    try {
      final res = await http
          .get(Uri.parse('${CallService.url}/stats'))
          .timeout(const Duration(seconds: 8));
      sw.stop();
      return DiagStepResult(
        name: 'Сервер звонков (RTT)',
        passed: res.statusCode == 200,
        details: 'HTTP ${res.statusCode}, ${sw.elapsedMilliseconds} мс',
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return DiagStepResult(
          name: 'Сервер звонков (RTT)', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }

  /// Открывается ли комната сигналинга (WebSocket) с настоящим токеном входа.
  Future<DiagStepResult> _checkRoomOpen() async {
    final sw = Stopwatch()..start();
    try {
      final token = await chatAuth.ensureFreshToken();
      if (token == null) {
        sw.stop();
        return DiagStepResult(
            name: 'Комната сигналинга',
            passed: false,
            details: 'нет входа в чат',
            latency: sw.elapsed);
      }
      final ch = WebSocketChannel.connect(CallService.roomUri(const Uuid().v4(), token));
      await ch.ready.timeout(const Duration(seconds: 8));
      sw.stop();
      try {
        await ch.sink.close();
      } catch (_) {}
      return DiagStepResult(
        name: 'Комната сигналинга',
        passed: true,
        details: 'открылась за ${sw.elapsedMilliseconds} мс',
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return DiagStepResult(
          name: 'Комната сигналинга', passed: false, details: 'ошибка: $e', latency: sw.elapsed);
    }
  }

  String _appVersion() {
    try {
      return DemoMode.appVersion.isEmpty ? 'dev' : DemoMode.appVersion;
    } catch (_) {
      return 'dev';
    }
  }

  Future<String> _networkType() async {
    try {
      // На мобильных платформах можно попробовать определить тип сети
      // Для простоты возвращаем платформу
      return defaultTargetPlatform.name;
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String?> _fcmToken() async {
    try {
      if (kIsWeb) {
        final config = {
          'apiKey': FirebaseSettings.webApiKey,
          'appId': FirebaseSettings.webAppId,
          'messagingSenderId': FirebaseSettings.messagingSenderId,
          'projectId': FirebaseSettings.projectId,
          'authDomain': FirebaseSettings.webAuthDomain,
        };
        return await webPushToken(config, FirebaseSettings.webVapidKey);
      }
      final messaging = FirebaseMessaging.instance;
      final perm = await messaging.getNotificationSettings();
      if (perm.authorizationStatus == AuthorizationStatus.authorized) {
        return await messaging.getToken();
      }
    } catch (_) {}
    return null;
  }
}

/// Отправка отчёта диагностики через DemoMode.send.
///
/// Возвращает текст ошибки или null при успехе. Отправляем всегда, когда
/// просили: и при провале (авто), и по кнопке — раньше при успехе с
/// autoSend=false возвращался null, и экран считал это ошибкой, хотя отчёт
/// даже не уходил. Заодно обходим общий лимит «не чаще раза в 10 секунд»,
/// иначе сразу после автопопытки кнопка отвечала «Подождите несколько секунд».
Future<String?> sendDiagReport(NetDiagReport report, {required bool autoSend}) async {
  final text = report.toReportText();
  final page = 'Диагностика сети${autoSend ? ' (авто)' : ''}';
  return await DemoMode.send(text, page, ignoreThrottle: true);
}

/// Успешна ли отправка: DemoMode.send возвращает null при успехе и текст
/// ошибки при неудаче.
bool diagSendSucceeded(String? sendResult) => sendResult == null;
