import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'ble_transport.dart';

/// P2P link abstraction (ARCHITECTURE.md §2 transport stage).
///
/// A real deployment implements this over Bluetooth RFCOMM / Wi-Fi Direct:
/// `send()` writes the raw iBFS frame to the socket, and unsolicited inbound
/// frames arrive on `incoming`. Nothing above this layer knows or cares which
/// radio carries the bytes.
abstract class Transport {
  /// Writes one frame onto the link; resolves after the radio accepts it.
  Future<int> send(Uint8List frame);

  /// Inbound frames from a connected peer.
  Stream<Uint8List> get incoming;

  /// Whether a peer is connected.
  bool get isConnected;

  /// Tear down the connection.
  Future<void> disconnect();
}

/// Loopback transport for development and demo (no radios needed).
///
/// Simulates a round-trip delay of [minMs]–[maxMs] milliseconds (default
/// 35–90 ms, matching RFCOMM benchmarks). No encryption, no real radio.
class LoopbackTransport implements Transport {
  final int minMs;
  final int maxMs;
  final _controller = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final _rng = Random();

  LoopbackTransport({this.minMs = 35, this.maxMs = 90});

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<int> send(Uint8List frame) async {
    if (!_connected) throw StateError('Transport not connected');

    final delay = minMs + _rng.nextInt(maxMs - minMs + 1);
    await Future.delayed(Duration(milliseconds: delay));

    // Loopback: echo the frame back on the incoming stream.
    if (!_controller.isClosed) {
      _controller.add(frame);
    }

    return delay;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _controller.close();
  }
}

/// Transport adapter exposing [BleMeshTransport] behind the [Transport]
/// interface used by the transceiver pipeline.
class BleTransportAdapter implements Transport {
  final BleMeshTransport _ble;

  BleTransportAdapter(this._ble);

  @override
  Stream<Uint8List> get incoming => _ble.incoming;

  @override
  bool get isConnected => _ble.isRunning;

  @override
  Future<int> send(Uint8List frame) {
    // Local origination: mark the sequence ID as seen so this packet is
    // not re-delivered to the app when it echoes back through the mesh.
    _ble.markOriginated(frame);
    return _ble.send(frame);
  }

  @override
  Future<void> disconnect() => _ble.stop();
}

/// Transport that starts on loopback (works everywhere, even without
/// Bluetooth) and can be switched to the BLE mesh once radios are up.
class SwitchableTransport implements Transport {
  Transport _active;
  final _controller = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  final BleMeshTransport mesh = BleMeshTransport.instance;

  SwitchableTransport() : _active = LoopbackTransport() {
    _wire();
  }

  void _wire() {
    _sub?.cancel();
    _sub = _active.incoming.listen(
      (frame) {
        if (!_controller.isClosed) _controller.add(frame);
      },
    );
  }

  /// Whether the BLE mesh is currently the active link.
  bool get meshActive => _active is BleTransportAdapter;

  /// Number of connected mesh peers (0 in loopback mode).
  int get meshPeerCount => mesh.peerCount;

  /// Attempt to start the BLE mesh; on success, all traffic moves from
  /// loopback to the radio. Returns `true` when mesh mode is active.
  Future<bool> enableMesh() async {
    if (meshActive) return true;
    final started = await mesh.start();
    if (!started) return false;
    _active = BleTransportAdapter(mesh);
    _wire();
    return true;
  }

  /// Drop back to loopback.
  Future<void> disableMesh() async {
    if (!meshActive) return;
    await mesh.stop();
    _active = LoopbackTransport();
    _wire();
  }

  @override
  Future<int> send(Uint8List frame) {
    // The BLE adapter marks locally originated frames for dedup.
    return _active.send(frame);
  }


  @override
  Stream<Uint8List> get incoming => _controller.stream;

  @override
  bool get isConnected => _active.isConnected;

  @override
  Future<void> disconnect() async {
    await _active.disconnect();
    await _controller.close();
  }
}
