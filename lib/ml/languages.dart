/// iTantra language registry — NETWORK_PROTOCOL.md §3 wire IDs.
///
/// Each language carries its BCP 47 locale string (for STT/TTS engines),
/// its 4-bit wire ID (for iBFS-v1 Lang nibble), and the relative paths
/// to its sherpa-onnx INT8 ONNX models (downloaded at first use via the
/// in-app model manager).
class Lang {
  final String code; // BCP 47
  final String name; // Display name
  final int wireId; // 4-bit wire code (0x0–0x09)
  final String iso639; // 2-letter shorthand for distress classifier
  final String sttModel; // Relative path to INT8 ONNX STT model
  final String sttTokens; // Relative path to STT tokens.txt
  final String ttsModel; // Relative path to VITS ONNX TTS model
  final String ttsTokens; // Relative path to TTS tokens.txt

  const Lang({
    required this.code,
    required this.name,
    required this.wireId,
    required this.iso639,
    required this.sttModel,
    required this.sttTokens,
    String? ttsModel,
    String? ttsTokens,
  })  : ttsModel = ttsModel ?? 'models/tts/$iso639/model.onnx',
        ttsTokens = ttsTokens ?? 'models/tts/$iso639/tokens.txt';

  @override
  String toString() => name;
}

/// Supported languages — order matches NETWORK_PROTOCOL.md §3 table.
///
/// Model paths are relative to the app's documents directory.
/// They are downloaded on first use via the in-app model manager.
const List<Lang> kLanguages = [
  Lang(
    code: 'hi-IN', name: 'Hindi', wireId: 0x0, iso639: 'hi',
    sttModel: 'models/stt/hi/model.int8.onnx',
    sttTokens: 'models/stt/hi/tokens.txt',
  ),
  Lang(
    code: 'gu-IN', name: 'Gujarati', wireId: 0x1, iso639: 'gu',
    sttModel: 'models/stt/gu/model.int8.onnx',
    sttTokens: 'models/stt/gu/tokens.txt',
  ),
  Lang(
    code: 'mr-IN', name: 'Marathi', wireId: 0x2, iso639: 'mr',
    sttModel: 'models/stt/mr/model.int8.onnx',
    sttTokens: 'models/stt/mr/tokens.txt',
  ),
  Lang(
    code: 'kn-IN', name: 'Kannada', wireId: 0x3, iso639: 'kn',
    sttModel: 'models/stt/kn/model.int8.onnx',
    sttTokens: 'models/stt/kn/tokens.txt',
  ),
  Lang(
    code: 'ta-IN', name: 'Tamil', wireId: 0x4, iso639: 'ta',
    sttModel: 'models/stt/ta/model.int8.onnx',
    sttTokens: 'models/stt/ta/tokens.txt',
  ),
  Lang(
    code: 'te-IN', name: 'Telugu', wireId: 0x5, iso639: 'te',
    sttModel: 'models/stt/te/model.int8.onnx',
    sttTokens: 'models/stt/te/tokens.txt',
  ),
  Lang(
    code: 'ml-IN', name: 'Malayalam', wireId: 0x6, iso639: 'ml',
    sttModel: 'models/stt/ml/model.int8.onnx',
    sttTokens: 'models/stt/ml/tokens.txt',
  ),
  // Odia: neither STT nor TTS models are available on HuggingFace yet.
  // Falls back to platform STT/TTS when model files are missing.
  Lang(
    code: 'or-IN', name: 'Odia', wireId: 0x7, iso639: 'or',
    sttModel: 'models/stt/or/model.int8.onnx',
    sttTokens: 'models/stt/or/tokens.txt',
  ),
  Lang(
    code: 'bn-IN', name: 'Bengali', wireId: 0x8, iso639: 'bn',
    sttModel: 'models/stt/bn/model.int8.onnx',
    sttTokens: 'models/stt/bn/tokens.txt',
  ),
  Lang(
    code: 'en-IN', name: 'English', wireId: 0x9, iso639: 'en',
    sttModel: 'models/stt/en/model.int8.onnx',
    sttTokens: 'models/stt/en/tokens.txt',
  ),
];

/// Look up a [Lang] by its 4-bit wire ID. Returns `null` for unknown IDs.
Lang? langByWireId(int id) {
  for (final l in kLanguages) {
    if (l.wireId == id) return l;
  }
  return null;
}

/// Look up a [Lang] by ISO 639 code. Returns `null` for unknown codes.
Lang? langByIso639(String code) {
  for (final l in kLanguages) {
    if (l.iso639 == code) return l;
  }
  return null;
}

/// English fallback language constant.
const Lang kEnglish = Lang(code: 'en-IN', name: 'English', wireId: 0x9, iso639: 'en', sttModel: 'models/stt/en/model.int8.onnx', sttTokens: 'models/stt/en/tokens.txt');

/// Hindi fallback language constant.
const Lang kHindi = Lang(code: 'hi-IN', name: 'Hindi', wireId: 0x0, iso639: 'hi', sttModel: 'models/stt/hi/model.int8.onnx', sttTokens: 'models/stt/hi/tokens.txt');
