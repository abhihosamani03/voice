import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'languages.dart';
import 'model_downloader.dart';

typedef SttResultCallback = void Function(String text, bool isFinal);

/// Offline speech-to-text engine using sherpa-onnx with AI4Bharat
/// IndicConformer INT8 ONNX models.
///
/// Architecture (docs/ML_PIPELINE.md §1, §3, §4):
/// - Model: AI4Bharat IndicConformer (NeMo CTC), INT8 quantized
/// - Runtime: sherpa-onnx (C++ core via Dart FFI)
/// - Input: 16kHz mono PCM from device microphone
/// - Output: transcribed text in the selected Indic language
///
/// Model files are downloaded to the app's documents directory on first
/// launch. See scripts/fetch_models.py for the download URLs.
///
/// IMPORTANT: If models are NOT yet downloaded, the engine falls back
/// gracefully — PTT still works but text will be empty/placeholder.
class SttEngine {
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.VadModelConfig? _vadConfig;
  AudioRecorder? _recorder;
  bool _initialized = false;
  String? _currentLocale;
  StreamSubscription<Uint8List>? _audioSubscription;
  final BytesBuilder _pcmBuffer = BytesBuilder(copy: false);

  // ── Model download state ──────────────────────────────────────
  bool _downloading = false;
  double _downloadProgress = 0.0;
  String? _downloadingLang;

  /// Whether a model download is currently in progress.
  bool get isDownloading => _downloading;

  /// Current download progress (0.0–1.0).
  double get downloadProgress => _downloadProgress;

  /// Language code currently being downloaded, if any.
  String? get downloadingLang => _downloadingLang;

  /// Check if models are available for [lang] (without initializing).
  Future<bool> hasModels(Lang lang) async {
    await _ensureBundledModel(lang);
    return ModelDownloader.areModelsAvailable(lang);
  }

  /// Ensure models are downloaded for [lang], then initialize the recognizer.
  ///
  /// Downloads models from HuggingFace if not already present.
  /// Returns `true` if models are ready, `false` if download failed.
  Future<bool> prepareModels(
    Lang lang, {
    DownloadProgressCallback? onProgress,
  }) async {
    await _ensureBundledModel(lang);
    if (await ModelDownloader.areModelsAvailable(lang)) {
      return true;
    }

    // Download models.
    _downloading = true;
    _downloadProgress = 0.0;
    _downloadingLang = lang.code;

    final success = await ModelDownloader.downloadModels(
      lang,
      onProgress: (progress) {
        _downloadProgress = progress;
        onProgress?.call(progress);
      },
    );

    _downloading = false;
    _downloadProgress = 0.0;
    _downloadingLang = null;

    return success;
  }

  /// Copy bundled asset models (e.g. Hindi) into app documents directory if present.
  Future<void> _ensureBundledModel(Lang lang) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelFile = File('${appDir.path}/${lang.sttModel}');
      final tokensFile = File('${appDir.path}/${lang.sttTokens}');

      if (!await modelFile.exists() || await modelFile.length() < 50000000) {
        try {
          final byteData = await rootBundle.load('assets/${lang.sttModel}');
          await modelFile.parent.create(recursive: true);
          await modelFile.writeAsBytes(byteData.buffer.asUint8List(
              byteData.offsetInBytes, byteData.lengthInBytes));
        } catch (_) {
          // Model not bundled in assets — will be downloaded dynamically if needed.
        }
      }

      if (!await tokensFile.exists() || await tokensFile.length() < 1000) {
        try {
          final byteData = await rootBundle.load('assets/${lang.sttTokens}');
          await tokensFile.parent.create(recursive: true);
          await tokensFile.writeAsBytes(byteData.buffer.asUint8List(
              byteData.offsetInBytes, byteData.lengthInBytes));
        } catch (_) {
          // Tokens not bundled in assets.
        }
      }
    } catch (_) {}
  }

  /// Copy VAD asset from Flutter bundle into app documents directory.
  Future<String?> _ensureVadModel() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final vadPath = '${appDir.path}/silero_vad.onnx';
      if (!await File(vadPath).exists()) {
        final byteData =
            await rootBundle.load('assets/models/vad/silero_vad.onnx');
        await File(vadPath).writeAsBytes(byteData.buffer.asUint8List(
            byteData.offsetInBytes, byteData.lengthInBytes));
      }
      return vadPath;
    } catch (e) {
      return null;
    }
  }

  /// Initialize the VAD only (no STT model required).
  /// Used so PTT recording can at least work before STT models load.
  Future<bool> initVad() async {
    if (_vad != null) return true;
    try {
      final vadPath = await _ensureVadModel();
      if (vadPath == null) return false;

      _vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          threshold: 0.5,
          minSilenceDuration: 0.6,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 30.0,
        ),
        numThreads: 2,
        provider: 'cpu',
      );

      _vad = sherpa.VoiceActivityDetector(
        config: _vadConfig!,
        bufferSizeInSeconds: 30.0,
      );
      return true;
    } catch (_) {
      _vad = null;
      return false;
    }
  }

  /// Initialize the recognizer for the given language.
  ///
  /// Models are loaded from the app's documents directory.
  /// If models don't exist yet, only VAD is initialized so
  /// PTT recording still works even without STT.
  ///
  /// Returns null on success, or an error string describing what failed.
  Future<String?> init(Lang lang) async {
    if (_initialized && _currentLocale == lang.code) return null;

    // Dispose previous recognizer if switching languages.
    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }

    // Always try to init VAD, even if STT model is missing.
    await initVad();

    // Ensure bundled asset models are unpacked first.
    await _ensureBundledModel(lang);

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/${lang.sttModel}';
      final tokensPath = '${appDir.path}/${lang.sttTokens}';

      // Check if model files exist.
      if (!await File(modelPath).exists() ||
          !await File(tokensPath).exists()) {
        // Models not downloaded yet.
        _initialized = false;
        return 'model files missing on disk';
      }

      // Verify files are not zero-byte (corrupted download).
      final modelSize = await File(modelPath).length();
      final tokensSize = await File(tokensPath).length();
      if (modelSize < 1000000) {
        // Model < 1 MB — definitely incomplete download, delete and retry.
        await File(modelPath).delete();
        _initialized = false;
        return 'model file incomplete ($modelSize bytes) — please retry download';
      }
      if (tokensSize == 0) {
        await File(tokensPath).delete();
        _initialized = false;
        return 'tokens file is empty — please retry download';
      }

      // Configure NeMo CTC recognizer (AI4Bharat IndicConformer).
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
              model: modelPath,
            ),
            tokens: tokensPath,
            numThreads: 2,
            provider: 'cpu',
            debug: true, // Enable debug so sherpa logs show in logcat.
          ),
          lm: const sherpa.OfflineLMConfig(
            model: '',
            scale: 0.1,
          ),
          decodingMethod: 'greedy_search',
          maxActivePaths: 1,
          hotwordsFile: '',
          hotwordsScore: 1.5,
          ruleFsts: '',
          ruleFars: '',
        ),
      );

      _currentLocale = lang.code;
      _initialized = true;
      return null; // success
    } catch (e, stack) {
      // Log the real error so it appears in logcat / flutter logs.
      debugPrint('[SttEngine] OfflineRecognizer init failed: $e');
      debugPrint('[SttEngine] Stack: $stack');
      _initialized = false;
      _recognizer = null;
      return e.toString(); // Return actual error for display.
    }
  }


  /// Start listening and transcribing.
  ///
  /// Records 16kHz mono PCM from the microphone and feeds it to the
  /// sherpa-onnx recognizer in chunks.
  ///
  /// If STT models are not ready yet, the PTT button will still capture audio
  /// and trigger an auto-download. While downloading, the UI shows progress.
  Future<void> start({
    required String localeId,
    required SttResultCallback onResult,
  }) async {
    // Find the Lang for this localeId.
    final lang = kLanguages.firstWhere(
      (l) => l.code == localeId,
      orElse: () => kEnglish,
    );

    // Always ensure VAD is ready first.
    await initVad();

    if (!_initialized || _currentLocale != localeId) {
      await init(lang);
    }

    if (!_initialized || _recognizer == null) {
      // Models not available — download them.
      // Use isFinal=false so status messages are NOT treated as transcripts.
      onResult('Downloading offline models…', false);

      final ready = await prepareModels(lang, onProgress: (progress) {
        onResult(
          'Downloading models… ${(progress * 100).toInt()}%',
          false, // false = interim status, not a final transcript
        );
      });

      if (!ready) {
        // isFinal=false so this status text isn't sent as a voice packet.
        onResult('Model download failed — check internet connection', false);
        return;
      }

      // Initialize with the newly downloaded models.
      final initErr = await init(lang);
      if (!_initialized || _recognizer == null) {
        // Show the REAL error from sherpa-onnx, not a generic message.
        onResult('Model load error: ${initErr ?? "unknown"}', false);
        return;
      }
    }

    await _startRecording(onResult);
  }

  /// Ensure we have mic permission and start recording.
  Future<void> _startRecording(SttResultCallback onResult) async {
    _recorder = AudioRecorder();
    final hasPerm = await _recorder!.hasPermission();
    if (!hasPerm) {
      onResult('Microphone permission denied', false);
      _recorder = null;
      return;
    }

    _pcmBuffer.clear();

    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    // Feed audio chunks to the buffer + recognizer.
    _audioSubscription = stream.listen((audioData) {
      _pcmBuffer.add(audioData);
      _processAudio(audioData, onResult);
    });
  }

  /// Process a chunk of PCM audio through the VAD + recognizer for live preview.
  void _processAudio(Uint8List pcmData, SttResultCallback onResult) {
    final float32Data = _pcm16ToFloat32(pcmData);

    final vad = _vad;
    if (vad != null) {
      vad.acceptWaveform(float32Data);

      while (vad.isDetected()) {
        final segment = vad.front();
        if (segment.samples.isNotEmpty) {
          _runRecognizer(segment.samples, onResult);
        }
        vad.pop();
      }
    }
  }

  void _runRecognizer(Float32List samples, SttResultCallback onResult) {
    final recognizer = _recognizer;
    if (recognizer == null) return;

    try {
      final stream = recognizer.createStream();
      stream.acceptWaveform(
        sampleRate: 16000,
        samples: samples,
      );
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      if (result.text.isNotEmpty) {
        onResult(result.text, false);
      }
      stream.free();
    } catch (_) {
      // Ignore per-chunk errors to avoid crashing the stream.
    }
  }

  /// Convert int16 PCM bytes to float32 array.
  Float32List _pcm16ToFloat32(Uint8List pcmBytes) {
    if (pcmBytes.length % 2 != 0) {
      // Pad to even length.
      pcmBytes = Uint8List.fromList([...pcmBytes, 0]);
    }
    final int16View = Int16List.view(pcmBytes.buffer);
    final float32List = Float32List(int16View.length);
    for (var i = 0; i < int16View.length; i++) {
      float32List[i] = int16View[i] / 32768.0;
    }
    return float32List;
  }

  /// Stop listening and decode the complete recorded audio buffer.
  Future<String?> stop() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _recorder?.stop();
    _recorder = null;

    final pcmBytes = _pcmBuffer.takeBytes();
    if (pcmBytes.isEmpty) return null;

    final float32Data = _pcm16ToFloat32(pcmBytes);
    // Needs at least 0.2s of audio (3200 samples @ 16kHz)
    if (float32Data.length < 3200) return null;

    final recognizer = _recognizer;
    if (recognizer == null) return null;

    try {
      final stream = recognizer.createStream();
      stream.acceptWaveform(
        sampleRate: 16000,
        samples: float32Data,
      );
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      stream.free();
      final text = result.text.trim();
      return text.isNotEmpty ? text : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the engine is currently listening.
  bool get isListening => _recorder != null;

  /// Whether the offline STT models are loaded and ready.
  bool get isReady => _initialized && _recognizer != null;

  /// Whether VAD (at minimum) is ready so PTT can capture audio.
  bool get vadReady => _vad != null;

  /// Current locale.
  String? get currentLocale => _currentLocale;

  /// Dispose resources.
  Future<void> dispose() async {
    await stop();
    _recognizer?.free();
    _recognizer = null;
    _vad?.free();
    _vad = null;
    _initialized = false;
  }
}
