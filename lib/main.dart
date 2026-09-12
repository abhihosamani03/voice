import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'core/theme.dart';
import 'ml/stt_engine.dart';
import 'ml/tts_engine.dart';
import 'net/transport.dart';
import 'state/battery_monitor.dart';
import 'state/transceiver_controller.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // sherpa-onnx >= 1.13 requires the native C API bindings to be loaded
  // before creating ANY runtime object (recognizer, VAD, TTS). Without
  // this, every engine call throws 'Please initialize sherpa-onnx first'.
  sherpa.initBindings();
  runApp(const iTantraApp());
}

class iTantraApp extends StatelessWidget {
  const iTantraApp({super.key});

  /// App-wide transport: starts on loopback, switchable to the BLE mesh.
  static final SwitchableTransport transport = SwitchableTransport();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final controller = TransceiverController(
              stt: SttEngine(),
              tts: TtsEngine(),
              transport: transport,
            );
            controller.loadLog();
            return controller;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final monitor = BatteryMonitor();
            monitor.startMonitoring();
            return monitor;
          },
        ),
      ],
      child: MaterialApp(
        title: 'iTantra',
        debugShowCheckedModeBanner: false,
        theme: iTantraTheme.dark,
        home: const HomeScreen(),
      ),
    );
  }
}
