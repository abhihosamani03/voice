import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Hold-to-talk PTT button.
///
/// Visual states mirror the transceiver phase:
/// - IDLE:    dark circle, saffron ring — press to talk
/// - RECORDING: pulsing saffron fill — release to send
/// - PROCESSING/TRANSMITTING: spinning indicator
class PttButton extends StatefulWidget {
  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final bool isActive;

  const PttButton({
    super.key,
    required this.onPressed,
    required this.onReleased,
    required this.isActive,
  });

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth.clamp(120.0, 200.0);
        return GestureDetector(
          onTapDown: (widget.isActive && !_holding)
              ? (_) {
                  setState(() => _holding = true);
                  widget.onPressed();
                }
              : null,
          onTapUp: (_) {
            if (_holding) {
              setState(() => _holding = false);
              widget.onReleased();
            }
          },
          onTapCancel: () {
            if (_holding) {
              setState(() => _holding = false);
              widget.onReleased();
            }
          },
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              final pulseScale = _holding ? 1.0 + _pulse.value * 0.08 : 1.0;
              final glowOpacity = _holding ? 0.3 + _pulse.value * 0.3 : 0.0;

              return Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: iTantraTheme.saffron.withValues(alpha: glowOpacity),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Transform.scale(
                  scale: pulseScale,
                  child: child,
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: _holding
                    ? RadialGradient(
                        colors: [
                          iTantraTheme.saffron,
                          iTantraTheme.saffronDark,
                        ],
                      )
                    : null,
                color: _holding ? null : iTantraTheme.surfaceLight,
                border: Border.all(
                  color: _holding
                      ? iTantraTheme.saffronLight
                      : iTantraTheme.saffron,
                  width: 3,
                ),
              ),
              child: Center(
                child: _holding
                    ? const Icon(
                        Icons.mic,
                        size: 48,
                        color: iTantraTheme.ink,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.mic,
                            size: 40,
                            color: widget.isActive
                                ? iTantraTheme.saffron
                                : iTantraTheme.textMuted,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.isActive ? 'HOLD TO TALK' : 'OFFLINE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                              color: widget.isActive
                                  ? iTantraTheme.saffron
                                  : iTantraTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
