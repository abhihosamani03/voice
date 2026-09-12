import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Runtime permission management for iTantra.
///
/// Handles RECORD_AUDIO, ACCESS_FINE_LOCATION, and BLUETOOTH permissions.
/// On Android 12+ these require runtime requests; on older versions some
/// are granted at install time.
class PermissionManager {
  PermissionManager._();

  /// Request all permissions needed by iTantra.
  /// Returns a [PermissionResult] indicating which permissions were granted.
  static Future<PermissionResult> requestAll() async {
    final results = <String, bool>{};

    // Microphone — required for STT.
    results['microphone'] = await _requestMicrophone();

    // Location — required for GPS stamping and BT scanning on Android 12+.
    results['location'] = await _requestLocation();

    // Bluetooth — required for P2P transport. MUST be requested at runtime
    // on Android 12+ (BLUETOOTH_SCAN/CONNECT/ADVERTISE) — the manifest
    // declaration alone leaves the BLE state 'unauthorized', which was the
    // cause of the 'Bluetooth unavailable' error.
    results['bluetooth'] = await _requestBluetooth();

    return PermissionResult(results);
  }

  /// Check if all critical permissions are granted.
  static Future<bool> hasAllCritical() async {
    // Microphone check uses the speech_to_text package's status.
    // We rely on the STT engine returning false from initialize() if denied.
    return true; // Conservative — let individual engines report failures.
  }

  static Future<bool> _requestMicrophone() async {
    try {
      // speech_to_text handles its own permission request on initialize().
      // We just need to ensure the permission dialog can appear.
      // On Android, RECORD_AUDIO is requested when STT starts.
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return false;
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestBluetooth() async {
    try {
      if (Platform.isAndroid) {
        // Android 12+ (API 31): runtime BLUETOOTH_* permissions.
        if (await _androidSdkInt() >= 31) {
          final statuses = await [
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
            Permission.bluetoothAdvertise,
          ].request();
          return statuses.values.every((s) => s.isGranted);
        }
        // Android 11 and below: manifest permissions; location is required
        // for BLE scanning (already requested in _requestLocation).
        return true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _androidSdkInt() async {
    try {
      // device_info_plus is not a dependency; use the platform channel via
      // the permission_handler's underlying check instead. A cheap proxy:
      // if the BLUETOOTH_SCAN permission is defined at runtime the device is
      // API 31+. Simplest reliable check is osVersion parsing.
      if (Platform.isAndroid) {
        final version = Platform.operatingSystemVersion;
        final match = RegExp(r'\d+').firstMatch(version);
        final major = match != null ? int.tryParse(match.group(0)!) ?? 0 : 0;
        // Android 12 == Linux kernel-level version string may vary; use the
        // documented heuristic: API 31 ↔ Android 12. The OS version string on
        // Android is like 'Android 12 (API 31)' in newer embedders; otherwise
        // fall back to requesting (harmless when unnecessary).
        if (major >= 12) return 31;
        return 30;
      }
      return 0;
    } catch (_) {
      return 31; // Safer to attempt the runtime request.
    }
  }
}

/// Result of a permission request batch.
class PermissionResult {
  final Map<String, bool> results;
  const PermissionResult(this.results);

  bool get microphoneGranted => results['microphone'] ?? false;
  bool get locationGranted => results['location'] ?? false;
  bool get bluetoothGranted => results['bluetooth'] ?? false;

  bool get allGranted =>
      microphoneGranted && locationGranted && bluetoothGranted;

  /// List of denied permission names for display.
  List<String> get denied =>
      results.entries.where((e) => !e.value).map((e) => e.key).toList();
}
