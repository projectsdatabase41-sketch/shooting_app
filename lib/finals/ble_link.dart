import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;

import 'local_link.dart';

/// Bluetooth LE для связи устройств одного тира: мост (Android) выступает сервером, остальные — клиентами.
/// Поверх этого байтового канала работают кадрирование и мост (`local_link.dart`, `finals_bridge.dart`).
///
/// ВАЖНО: эта привязка проверена только компиляцией; на настоящих устройствах (Android ↔ Android/iPhone) её
/// предстоит проверить. Сеть (realtime) остаётся основным каналом и запасным вариантом.
class FinalsBle {
  FinalsBle._();

  static final UUID service = UUID.fromString('7f1f0001-6e6f-4e65-7875-732d66696e61');
  static final UUID rxChar = UUID.fromString('7f1f0002-6e6f-4e65-7875-732d66696e61'); // клиент → мост (запись)
  static final UUID txChar = UUID.fromString('7f1f0003-6e6f-4e65-7875-732d66696e61'); // мост → клиент (уведомления)

  /// Размер пакета, на который рассчитано кадрирование (меньше — надёжнее при малом MTU, больше — меньше кадров).
  static const int packet = 100;

  /// Мост на ПК/вебе не поддерживается, клиент в вебе — только в Chromium (здесь не используем).
  static bool get supported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// Только Android умеет быть мостом (сервером) надёжно.
  static bool get canBridge {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Короткая метка финала в имени устройства (чтобы устройства разных финалов рядом не путались);
  /// секрет канала из неё не восстановить.
  static String tagOf(String finalKey) => 'NX${md5.convert(finalKey.codeUnits).toString().substring(0, 4)}';
}

/// Связь с одним клиентом на стороне моста.
class _ServerLink implements LocalLink {
  _ServerLink(this._pm, this._central, this._tx, this.maxPacket);

  final PeripheralManager _pm;
  final Central _central;
  final GATTCharacteristic _tx;
  bool _open = true;

  @override
  final int maxPacket;
  @override
  void Function(Uint8List data)? onData;
  @override
  void Function()? onClosed;

  @override
  bool get isOpen => _open;

  @override
  Future<bool> send(Uint8List data) async {
    if (!_open) return false;
    try {
      await _pm.notifyCharacteristic(_central, _tx, value: data);
      return true;
    } catch (e) {
      debugPrint('BLE notify: $e');
      return false;
    }
  }

  void _gone() {
    if (!_open) return;
    _open = false;
    onClosed?.call();
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    unawaited(_pm.disconnect(_central).catchError((_) {}));
    onClosed?.call();
  }
}

/// Мост (Android): рекламирует службу и принимает клиентов; каждый клиент — отдельная [LocalLink].
class BleBridgeServer {
  BleBridgeServer(this.finalKey);

  final String finalKey;
  final PeripheralManager _pm = PeripheralManager();
  final _links = <String, _ServerLink>{};
  final _conn = StreamController<LocalLink>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  late final GATTCharacteristic _rx = GATTCharacteristic.mutable(
    uuid: FinalsBle.rxChar,
    properties: [GATTCharacteristicProperty.write, GATTCharacteristicProperty.writeWithoutResponse],
    permissions: [GATTCharacteristicPermission.write],
    descriptors: [],
  );
  late final GATTCharacteristic _tx = GATTCharacteristic.mutable(
    uuid: FinalsBle.txChar,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );

  /// Подключившиеся клиенты.
  Stream<LocalLink> get connections => _conn.stream;

  /// Запускает рекламу службы. `false` — Bluetooth недоступен или нет разрешения.
  Future<bool> start() async {
    if (!FinalsBle.canBridge) return false;
    try {
      if (!await _pm.authorize()) return false;
      await _pm.removeAllServices();
      await _pm.addService(GATTService(uuid: FinalsBle.service, isPrimary: true, includedServices: [], characteristics: [_rx, _tx]));
      _subs.add(_pm.characteristicWriteRequested.listen((e) async {
        final id = e.central.uuid.toString();
        var link = _links[id];
        if (link == null) {
          link = _ServerLink(_pm, e.central, _tx, FinalsBle.packet);
          _links[id] = link;
          _conn.add(link);
        }
        try {
          await _pm.respondWriteRequest(e.request);
        } catch (_) {}
        link.onData?.call(e.request.value);
      }));
      _subs.add(_pm.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) _links.remove(e.central.uuid.toString())?._gone();
      }));
      await _pm.startAdvertising(Advertisement(name: FinalsBle.tagOf(finalKey), serviceUUIDs: [FinalsBle.service]));
      return true;
    } catch (e) {
      debugPrint('BLE bridge start: $e');
      return false;
    }
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final l in _links.values.toList()) {
      l.close();
    }
    _links.clear();
    try {
      await _pm.stopAdvertising();
    } catch (_) {}
    await _conn.close();
  }
}

/// Связь клиента с мостом.
class _ClientLink implements LocalLink {
  _ClientLink(this._cm, this._peripheral, this._rx, this.maxPacket);

  final CentralManager _cm;
  final Peripheral _peripheral;
  final GATTCharacteristic _rx;
  bool _open = true;

  @override
  final int maxPacket;
  @override
  void Function(Uint8List data)? onData;
  @override
  void Function()? onClosed;

  @override
  bool get isOpen => _open;

  @override
  Future<bool> send(Uint8List data) async {
    if (!_open) return false;
    try {
      await _cm.writeCharacteristic(_peripheral, _rx, value: data, type: GATTCharacteristicWriteType.withResponse);
      return true;
    } catch (e) {
      debugPrint('BLE write: $e');
      return false;
    }
  }

  void _gone() {
    if (!_open) return;
    _open = false;
    onClosed?.call();
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    unawaited(_cm.disconnect(_peripheral).catchError((_) {}));
    onClosed?.call();
  }
}

/// Клиент: находит мост своего финала по метке в имени и подключается к нему.
class BleBridgeClient {
  BleBridgeClient(this.finalKey);

  final String finalKey;

  /// Ищет мост до [timeout] и подключается; `null` — не нашли или не удалось.
  Future<LocalLink?> connect({Duration timeout = const Duration(seconds: 12)}) async {
    if (!FinalsBle.supported) return null;
    final cm = CentralManager();
    final subs = <StreamSubscription<dynamic>>[];
    try {
      if (!await cm.authorize()) return null;
      final found = Completer<Peripheral>();
      final tag = FinalsBle.tagOf(finalKey);
      subs.add(cm.discovered.listen((e) {
        if (!found.isCompleted && e.advertisement.name == tag) found.complete(e.peripheral);
      }));
      await cm.startDiscovery(serviceUUIDs: [FinalsBle.service]);
      final Peripheral peripheral;
      try {
        peripheral = await found.future.timeout(timeout);
      } on TimeoutException {
        return null;
      } finally {
        await cm.stopDiscovery();
      }
      await cm.connect(peripheral);
      try {
        await cm.requestMTU(peripheral, mtu: 247);
      } catch (_) {
        // iOS не позволяет задать MTU — пакеты остаются в пределах согласованного
      }
      final services = await cm.discoverGATT(peripheral);
      final svc = services.firstWhere((s) => s.uuid == FinalsBle.service);
      final rx = svc.characteristics.firstWhere((c) => c.uuid == FinalsBle.rxChar);
      final tx = svc.characteristics.firstWhere((c) => c.uuid == FinalsBle.txChar);
      final link = _ClientLink(cm, peripheral, rx, FinalsBle.packet);
      subs.add(cm.characteristicNotified.listen((e) {
        if (e.peripheral.uuid == peripheral.uuid && e.characteristic.uuid == FinalsBle.txChar) link.onData?.call(e.value);
      }));
      subs.add(cm.connectionStateChanged.listen((e) {
        if (e.peripheral.uuid == peripheral.uuid && e.state == ConnectionState.disconnected) link._gone();
      }));
      await cm.setCharacteristicNotifyState(peripheral, tx, state: true);
      return link;
    } catch (e) {
      debugPrint('BLE client connect: $e');
      for (final s in subs) {
        unawaited(s.cancel());
      }
      return null;
    }
  }
}
