import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';
import 'tts_model_downloader.dart';

/// Offline text-to-speech back end.
///
/// PRIMARY: sherpa-onnx VITS (MMS) neural TTS, fully on-device after a
/// one-time ~114 MB model download per language.
/// FALLBACK: platform synthesizer (FlutterTts) when the neural model is
/// missing (e.g. Odia) or not yet downloaded.
class TtsEngine {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  sherpa.OfflineTts? _neural;
  String? _neuralLangIso;
  bool _platformConfigured = false;
  String? _currentBcp47;

  /// Whether the neural VITS engine is active for the current language.
  bool get isNeuralReady => _neural != null;

  /// Whether the neural VITS engine is active for a specific language.
  bool isNeuralReadyFor(Lang lang) =>
      _neural != null && _neuralLangIso == lang.iso639;

  /// Load the neural TTS model for [lang] if it is downloaded.
  /// Returns `true` when the neural engine is ready for [lang].
  Future<bool> initNeural(Lang lang) async {
    // Already loaded for this language?
    if (_neural != null && _neuralLangIso == lang.iso639) return true;

    // Free previous instance before loading a new one.
    _freeNeural();

    if (!TtsModelDownloader.hasNeuralModel(lang)) return false;
    if (!await TtsModelDownloader.areModelsAvailable(lang)) return false;

    try {
      final paths = await TtsModelDownloader.ttsPaths(lang);
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: paths.model,
            tokens: paths.tokens,
            dataDir: '', // No espeak-ng dataDir needed for MMS models.
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
        ruleFsts: '',
        maxNumSenetences: 1,
      );
      _neural = sherpa.OfflineTts(config);
      _neuralLangIso = lang.iso639;
      return true;
    } catch (e) {
      _neural = null;
      _neuralLangIso = null;
      return false;
    }
  }

  void _freeNeural() {
    try {
      _neural?.free();
    } catch (_) {}
    _neural = null;
    _neuralLangIso = null;
  }

  /// Configure the platform fallback for the given BCP 47 locale.
  Future<void> _configurePlatform(String bcp47) async {
    if (_platformConfigured && _currentBcp47 == bcp47) return;
    await _tts.setLanguage(bcp47);
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _currentBcp47 = bcp47;
    _platformConfigured = true;
  }

  /// Configure the engine for the given BCP 47 locale.
  /// No-op if already configured for the same locale.
  Future<void> configure(String bcp47, {required double speechRate}) async {
    await _configurePlatform(bcp47);
  }

  /// Speak [text] aloud.
  ///
  /// When [emergency] is true, volume is forced to maximum and routed to
  /// the alarm stream (ARCHITECTURE.md §2.3). This requires the
  /// MODIFY_AUDIO_SETTINGS permission.
  ///
  /// Uses the neural VITS engine when its model is loaded for this
  /// language; otherwise falls back to the platform synthesizer.
  Future<void> speak(String text, {bool emergency = false, String? langCode}) async {
    if (text.isEmpty) return;

    if (emergency) {
      // Request max media volume at the system level.
      try {
        const channel = MethodChannel('itantra/audio_override');
        await channel.invokeMethod('setMaxVolume');
      } on PlatformException {
        // Override not available — continue at current volume.
      } on MissingPluginException {
        // Not running on Android — ignore.
      }
    }

    // ── Neural path (sherpa-onnx VITS) ──
    final neural = _neural;
    if (neural != null) {
      try {
        final audio = neural.generate(
          text: text,
          sid: 0,
          speed: emergency ? 1.1 : 1.0,
        );
        if (audio.samples.isNotEmpty) {
          var hasAudibleSound = false;
          for (final s in audio.samples) {
            if (s.abs() > 0.001) {
              hasAudibleSound = true;
              break;
            }
          }
          if (hasAudibleSound) {
            await _playPcm(
              audio.samples,
              audio.sampleRate,
              emergency: emergency,
            );
            return;
          }
        }
      } catch (_) {
        // Neural synthesis failed — fall through to platform TTS.
      }
    }

    // ── Platform fallback (FlutterTts) ──
    final bcp47 = langCode ?? _currentBcp47 ?? 'hi-IN';
    await _configurePlatform(bcp47);
    if (emergency) {
      await _tts.setVolume(1.0);
      await _tts.setSpeechRate(0.6); // slightly faster for urgency
    } else {
      await _tts.setVolume(1.0);
      await _tts.setSpeechRate(0.5);
    }

    await _tts.speak(text);
    await _tts.awaitSpeakCompletion(true);

    if (emergency) {
      await _tts.setVolume(1.0);
      await _tts.setSpeechRate(0.5);
    }
  }

  /// Encode float PCM samples as a 16-bit WAV file and play it.
  Future<void> _playPcm(
    Float32List samples,
    int sampleRate, {
    bool emergency = false,
  }) async {
    final wav = _encodeWav(samples, sampleRate);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/itantra_tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);

    try {
      await _player.stop();
      // Emergency: force media volume to maximum before playback.
      if (emergency) {
        try {
          const channel = MethodChannel('itantra/audio_override');
          await channel.invokeMethod('setMaxVolume');
        } on PlatformException {
          // Ignore.
        }
      }
      await _player.play(DeviceFileSource(file.path));
      // Wait for playback to finish so callers can measure TTS duration.
      await _player.onPlayerComplete.first;
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Encode mono float samples [-1, 1] into a WAV (PCM 16-bit) byte blob.
  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    final numSamples = samples.length;
    const bytesPerSample = 2;
    final dataSize = numSamples * bytesPerSample;
    final buffer = ByteData(44 + dataSize);

    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i) & 0xFF);
      }
    }

    // RIFF header
    writeAscii(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');

    // fmt chunk
    writeAscii(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // PCM chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM format
    buffer.setUint16(22, 1, Endian.little); // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * bytesPerSample, Endian.little); // byte rate
    buffer.setUint16(32, bytesPerSample, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample

    // data chunk
    writeAscii(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    var offset = 44;
    for (var i = 0; i < numSamples; i++) {
      var s = samples[i];
      if (s > 1.0) s = 1.0;
      if (s < -1.0) s = -1.0;
      buffer.setInt16(offset, (s * 32767).round(), Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }

  /// Whether the engine has been configured.
  bool get isConfigured => _platformConfigured || _neural != null;

  /// Stop any ongoing speech.
  Future<void> stop() async {
    await _player.stop();
    await _tts.stop();
  }

  /// Dispose resources.
  Future<void> dispose() async {
    await _player.stop();
    await _player.dispose();
    await _tts.stop();
    _freeNeural();
    _platformConfigured = false;
  }
}
