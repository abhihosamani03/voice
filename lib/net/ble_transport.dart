import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

/// BLE GATT mesh transport (NETWORK_PROTOCOL.md §2 transport stage).
///
/// Every device runs BOTH roles simultaneously:
///  - Peripheral: advertises the iTantra service and accepts writes.
///  - Central: scans for other iTantra peripherals, connects, subscribes.
///
/// A frame received from any peer is delivered to the app once (dedup by
/// sequence ID) and re-broadcast to all OTHER peers — flooding relay.
class BleMeshTransport {
  BleMeshTransport._();

  static final BleMeshTransport instance = BleMeshTransport._();

  // ── iTantra GATT identifiers (custom 128-bit UUIDs) ──────────────
  static final UUID serviceUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a10');
  static final UUID frameCharUuid =
      UUID.fromString('8f1d3a50-6f2c-4c1e-9b7a-5a2e9d0c1a11');

  final PeripheralManager _peripheral = PeripheralManager();
  final CentralManager _central = CentralManager();

  final _controller = StreamController<Uint8List>.broadcast();
  final Map<UUID, Peripheral> _connected = {};
  final Map<UUID, GATTCharacteristic> _peerFrameChars = {};
  final Set<Central> _subscribedCentrals = {};

  /// Dedup cache: sequence ID → arrival ms. Frames are identified by the
  /// uint32 sequence ID (iBFS bytes 4–7); each ID is processed once.
  final Map<int, int> _seenIds = {};

  GATTCharacteristic? _frameChar;
  bool _running = false;
  StreamSubscription? _subDiscovered;
  StreamSubscription? _subConn;
  StreamSubscription? _subNotified;
  StreamSubscription? _subWrite;
  StreamSubscription? _subNotifyState;

  /// Inbound (and relayed) iBFS frames from the mesh.
  Stream<Uint8List> get incoming => _controller.stream;

  /// Whether the mesh layer is running.
  bool get isRunning => _running;

  /// Number of currently connected mesh peers.
  int get peerCount => _connected.length;

  /// Start advertising + scanning.
  ///
  /// IMPORTANT ordering (this was the 'Bluetooth unavailable' bug):
  /// 1. `authorize()` — shows the Android runtime permission dialog and
  ///    must run BEFORE any state check. The state is reported as
  ///    `unauthorized` until the user grants the BT permissions, so a
  ///    naive `state != poweredOn → return false` always failed here.
  /// 2. Wait (briefly) for the state stream to settle at `poweredOn`.
  /// 3. Only then set up GATT + advertising + discovery.
  Future<bool> start() async {
    if (_running) return true;
    try {
      // ── Step 1: request permissions (both roles) ──
      final centralOk = await _central.authorize();
      if (!centralOk) {
        debugPrint('BleMesh: central authorize denied');
        return false;
      }
      // Peripheral authorize requests BLUETOOTH_ADVERTISE.
      try {
        await _peripheral.authorize();
      } catch (e) {
        debugPrint('BleMesh: peripheral authorize failed: $e');
      }

      // ── Step 2: wait for the radio to be powered on ──
      if (!await _waitForPoweredOn()) return false;

      // ── Step 3: peripheral role — publish service & advertise ──
      _frameChar = GATTCharacteristic.mutable(
        uuid: frameCharUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      final service = GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_frameChar!],
      );
      await _peripheral.addService(service);

      // The service UUID MUST be in the advertisement — the central role
      // filters scans on it, and peers filter discovered peripherals on it.
      await _peripheral.startAdvertising(Advertisement(
        name: 'iTantra',
        serviceUUIDs: [serviceUuid],
      ));

      // ── Event wiring ──
      _subDiscovered = _central.discovered.listen(_onDiscovered);
      _subConn = _central.connectionStateChanged.listen(_onCentralConnChanged);
      _subNotified = _central.characteristicNotified.listen(_onNotified);
      _subWrite =
          _peripheral.characteristicWriteRequested.listen(_onWriteRequested);
      _subNotifyState =
          _peripheral.characteristicNotifyStateChanged.listen((args) {
        if (args.characteristic.uuid != frameCharUuid) return;
        if (args.state) {
          _subscribedCentrals.add(args.central);
        } else {
          _subscribedCentrals.remove(args.central);
        }
      });

      // ── Central role: scan for other iTantra peripherals ──
      await _central.startDiscovery(serviceUUIDs: [serviceUuid]);

      _running = true;
      debugPrint('BleMesh: started (advertising + scanning)');
      return true;
    } catch (e) {
      debugPrint('BleMeshTransport.start failed: $e');
      await stop();
      return false;
    }
  }

  /// Poll the state (refreshes it on Android) and wait up to ~4 s for
  /// `poweredOn`. Fails fast with a precise reason on other states.
  Future<bool> _waitForPoweredOn() async {
    // Nudge the state machine: getState() is also refreshed on resume by
    // the package, but polling makes it deterministic here.
    const maxWaits = 8; // 8 × 500 ms = 4 s
    for (var i = 0; i < maxWaits; i++) {
      final state = _central.state;
      switch (state) {
        case BluetoothLowEnergyState.poweredOn:
          return true;
        case BluetoothLowEnergyState.unsupported:
          debugPrint('BleMesh: BLE unsupported on this device');
          return false;
        case BluetoothLowEnergyState.unauthorized:
          debugPrint('BleMesh: Bluetooth permissions not granted');
          return false;
        case BluetoothLowEnergyState.poweredOff:
          debugPrint('BleMesh: Bluetooth is powered off');
          return false;
        case BluetoothLowEnergyState.unknown:
          // State still settling — wait and retry.
          await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    debugPrint('BleMesh: Bluetooth state did not settle (still unknown)');
    return false;
  }

  /// Send an iBFS frame: write to every connected peer (they relay) and
  /// notify directly-subscribed centrals.
  ///
  /// [excludePeripheral] / [excludeCentral] are used by the relay path so a
  /// frame is never echoed back to the peer it came from.
  Future<int> send(
    Uint8List frame, {
    Peripheral? excludePeripheral,
    Central? excludeCentral,
  }) async {
    if (!_running) throw StateError('BLE mesh not started');
    var fanout = 0;

    // Write to other peripherals we are connected to as central.
    for (final entry in _connected.entries) {
      if (excludePeripheral != null && entry.key == excludePeripheral.uuid) {
        continue;
      }
      final char = _peerFrameChars[entry.key];
      if (char == null) continue;
      try {
        await _central.writeCharacteristic(
          entry.value,
          char,
          value: frame,
          type: GATTCharacteristicWriteType.withoutResponse,
        );
        fanout++;
      } catch (e) {
        debugPrint('BLE write to ${entry.key} failed: $e');
      }
    }

    // Notify subscribed centrals (peripheral role).
    final char = _frameChar;
    if (char != null) {
      for (final central in List.of(_subscribedCentrals)) {
        if (excludeCentral != null && central.uuid == excludeCentral.uuid) {
          continue;
        }
        try {
          await _peripheral.notifyCharacteristic(
            central,
            char,
            value: frame,
          );
          fanout++;
        } catch (e) {
          debugPrint('BLE notify failed: $e');
        }
      }
    }

    return fanout;
  }

  void _onDiscovered(DiscoveredEventArgs args) {
    final key = args.peripheral.uuid;
    if (_connected.containsKey(key)) return;
    if ((args.advertisement.serviceUUIDs).contains(serviceUuid)) {
      debugPrint('BleMesh: discovered iTantra peer $key');
      // Fire-and-forget connect; results arrive via connectionStateChanged.
      _central.connect(args.peripheral).then((_) {}, onError: (e) {
        debugPrint('BLE connect to $key failed: $e');
      });
    }
  }

  void _onCentralConnChanged(PeripheralConnectionStateChangedEventArgs args) {
    final key = args.peripheral.uuid;
    if (args.state == ConnectionState.connected) {
      debugPrint('BleMesh: connected to peer $key');
      _connected[key] = args.peripheral;
      _subscribeAndRequestMtu(args.peripheral);
    } else {
      debugPrint('BleMesh: peer $key disconnected (${args.state})');
      _connected.remove(key);
      _peerFrameChars.remove(key);
    }
  }

  Future<void> _subscribeAndRequestMtu(Peripheral peripheral) async {
    try {
      await _central.requestMTU(peripheral, mtu: 517);
      final services = await _central.discoverGATT(peripheral);
      for (final service in services) {
        if (service.uuid != serviceUuid) continue;
        for (final char in service.characteristics) {
          if (char.uuid == frameCharUuid) {
            _peerFrameChars[peripheral.uuid] = char;
            await _central.setCharacteristicNotifyState(
              peripheral,
              char,
              state: true,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('BLE subscribe failed: $e');
    }
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.characteristic.uuid != frameCharUuid) return;
    _dispatch(args.value, excludePeripheral: args.peripheral);
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs args,
  ) async {
    try {
      await _peripheral.respondWriteRequest(args.request);
      _dispatch(args.request.value, excludeCentral: args.central);
    } catch (e) {
      debugPrint('BLE write response failed: $e');
    }
  }

  /// Dedup + relay logic. Frames are identified by the uint32 sequence ID
  /// (bytes 4–7 of the iBFS header). Each ID is delivered to the app once
  /// and relayed once to all other peers — flooding without loops.
  void _dispatch(
    Uint8List frame, {
    Peripheral? excludePeripheral,
    Central? excludeCentral,
  }) {
    if (frame.length < 8) return;
    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);

    final now = DateTime.now().millisecondsSinceEpoch;
    // Evict cache entries older than 60 s to bound memory.
    if (_seenIds.length > 512) {
      _seenIds.removeWhere((_, t) => now - t > 60000);
      if (_seenIds.length > 512) _seenIds.clear();
    }
    if (_seenIds.containsKey(id)) return; // Already seen — don't relay again.
    _seenIds[id] = now;

    if (!_controller.isClosed) _controller.add(frame);

    // Relay to OTHER peers (never echo back to the source).
    send(frame,
            excludePeripheral: excludePeripheral, excludeCentral: excludeCentral)
        .then((_) {}, onError: (e) {
      debugPrint('BLE relay failed: $e');
    });
  }

  /// Mark a locally originated frame ID as seen so we don't re-deliver our
  /// own packet when it echoes back through the mesh.
  void markOriginated(Uint8List frame) {
    if (frame.length < 8) return;
    final id = ByteData.sublistView(frame).getUint32(4, Endian.big);
    _seenIds[id] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Stop the mesh and release radios.
  Future<void> stop() async {
    _running = false;
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    for (final p in List.of(_connected.values)) {
      try {
        await _central.disconnect(p);
      } catch (_) {}
    }
    _connected.clear();
    _peerFrameChars.clear();
    _subscribedCentrals.clear();
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    await _subDiscovered?.cancel();
    await _subConn?.cancel();
    await _subNotified?.cancel();
    await _subWrite?.cancel();
    await _subNotifyState?.cancel();
    _subDiscovered = _subConn = _subNotified = _subWrite = _subNotifyState =
        null;
  }

  /// Tear down completely.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
