import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Full-screen emergency alarm overlay (ARCHITECTURE.md §2.3).
///
/// Non-dismissible — appears on emergency packets, pulses red, forces
/// screen wake, and auto-clears after [durationSeconds].
class AlarmOverlay extends StatefulWidget {
  final int durationSeconds;

  const AlarmOverlay({
    super.key,
    this.durationSeconds = 9,
  });

  @override
  State<AlarmOverlay> createState() => _AlarmOverlayState();
}

class _AlarmOverlayState extends State<AlarmOverlay>
    with TickerProviderStateMixin {
  late AnimationController _pulse;
  late AnimationController _countdown;

  @override
  void initState() {
    super.initState();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _countdown = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.durationSeconds),
    )..forward();

    // Keep screen on during alarm.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _countdown.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final opacity = 0.85 + _pulse.value * 0.15;
          return Container(
            color: iTantraTheme.danger.withValues(alpha: opacity),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Pulsing icon
                  AnimatedScale(
                    scale: 1.0 + _pulse.value * 0.15,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      size: 80,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Title
                  const Text(
                    'EMERGENCY',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Subtitle
                  Text(
                    'SOS signal received',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 40),

                  // Countdown bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 60),
                    child: AnimatedBuilder(
                      animation: _countdown,
                      builder: (context, _) {
                        return Column(
                          children: [
                            LinearProgressIndicator(
                              value: 1.0 - _countdown.value,
                              backgroundColor: Colors.white.withValues(alpha: 0.3),
                              valueColor:
                                  const AlwaysStoppedAnimation(Colors.white),
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Auto-clears in ${((1.0 - _countdown.value) * widget.durationSeconds).ceil()}s',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
