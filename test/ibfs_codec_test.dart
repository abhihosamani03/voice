import 'dart:typed_data' show Uint8List;

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';

void main() {
  group('iBFS encode/decode round-trip', () {
    test('plain text packet survives a round-trip', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kHindi,
        sequenceId: 42,
        text: 'मदद करो',
      );
      final frame = encodeIbfs(packet);
      final decoded = decodeIbfs(frame);

      expect(decoded.type, PacketType.pttVoice);
      expect(decoded.priority, Priority.routine);
      expect(decoded.language.iso639, 'hi');
      expect(decoded.sequenceId, 42);
      expect(decoded.text, 'मदद करो');
    });

    test('GPS-stamped packet preserves coordinates', () {
      const lat = 30.7333;
      const lon = 79.0667; // Himalayan valley coordinates
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.emergency,
        language: kHindi,
        sequenceId: 7,
        text: 'मदद करो, मैं घाटी में गिर गया हूँ',
        flags: const PayloadFlags(hasGps: true),
        latitude: lat,
        longitude: lon,
      );
      final decoded = decodeIbfs(encodeIbfs(packet));

      expect(decoded.flags.hasGps, isTrue);
      // Float32 precision — compare with tolerance.
      expect(decoded.latitude!, closeTo(lat, 0.001));
      expect(decoded.longitude!, closeTo(lon, 0.001));
      expect(decoded.priority, Priority.emergency);
    });

    test('multi-byte UTF-8 (Kannada) round-trips correctly', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: langByIso639('kn')!,
        sequenceId: 99,
        text: 'ಸಹಾಯ ಮಾಡಿ',
      );
      final decoded = decodeIbfs(encodeIbfs(packet));
      expect(decoded.text, 'ಸಹಾಯ ಮಾಡಿ');
      expect(decoded.language.iso639, 'kn');
    });

    test('frame overhead is 14 bytes + payload', () {
      final packet = IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hi',
      );
      final frame = encodeIbfs(packet);
      // 10 header + 1 flags + 2 text + 2 CRC = 15.
      expect(frame.length, 15);
    });

    test('magic bytes are IT', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
      ));
      expect(frame[0], 0x49);
      expect(frame[1], 0x54);
    });
  });

  group('iBFS validation', () {
    test('corrupted payload is rejected (CRC mismatch)', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'hello',
      ));
      // Flip a payload byte.
      frame[12] ^= 0xFF;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });

    test('bad magic is rejected', () {
      final frame = encodeIbfs(IbfPacket(
        type: PacketType.pttVoice,
        priority: Priority.routine,
        language: kEnglish,
        sequenceId: 1,
        text: 'x',
      ));
      frame[0] = 0x00;
      expect(() => decodeIbfs(frame), throwsA(isA<IbfDecodeError>()));
    });

    test('truncated frame is rejected', () {
      expect(() => decodeIbfs(Uint8List.fromList([0x49, 0x54, 0x11])),
          throwsA(isA<IbfDecodeError>()));
    });
  });

  group('distress detection', () {
    test('Hindi distress keywords are detected', () {
      expect(detectDistress('मदद करो, मैं घाटी में गिर गया हूँ', 'hi'), isTrue);
      expect(detectDistress('बचाओ!', 'hi'), isTrue);
    });

    test('routine Hindi text is not flagged', () {
      expect(detectDistress('नमस्ते, कैसे हो?', 'hi'), isFalse);
    });

    test('English keywords are detected', () {
      expect(detectDistress('I am injured, send help', 'en'), isTrue);
      expect(detectDistress('hello world', 'en'), isFalse);
    });

    test('Kannada keywords are detected', () {
      expect(detectDistress('ಸಹಾಯ ಮಾಡಿ', 'kn'), isTrue);
    });

    test('unknown language falls back to English keywords', () {
      expect(detectDistress('emergency!', 'xx'), isTrue);
    });
  });
}
