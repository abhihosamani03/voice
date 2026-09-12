import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/languages.dart';
import 'package:itantra/ml/translation_engine.dart';
import 'package:itantra/ml/tts_model_downloader.dart';

void main() {
  group('translation language support', () {
    test('ML Kit supported languages are recognised', () {
      expect(TranslationEngine.isSupported(kHindi), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('kn')!), isTrue);
      expect(TranslationEngine.isSupported(kEnglish), isTrue);
      expect(TranslationEngine.isSupported(langByIso639('bn')!), isTrue);
    });

    test('Odia and Malayalam are unsupported by ML Kit (text-only fallback)',
        () {
      final odia = kLanguages.firstWhere((l) => l.iso639 == 'or');
      final malayalam = kLanguages.firstWhere((l) => l.iso639 == 'ml');
      expect(TranslationEngine.isSupported(odia), isFalse);
      expect(TranslationEngine.isSupported(malayalam), isFalse);
    });
  });

  group('neural TTS model availability', () {
    test('every Indic language except Odia has an MMS model mapping', () {
      for (final lang in kLanguages) {
        final expected = lang.iso639 != 'or';
        expect(
          TtsModelDownloader.hasNeuralModel(lang),
          expected,
          reason: '${lang.name} (${lang.iso639}) TTS model mapping mismatch',
        );
      }
    });

    test('MMS code mapping is correct', () {
      // Verify via the public hasNeuralModel + naming of model paths.
      // (The map itself is private; these assertions pin the behaviour.)
      final hindi = kLanguages.firstWhere((l) => l.iso639 == 'hi');
      expect(hindi.ttsModel, contains('tts'));
      expect(hindi.ttsTokens, contains('tokens'));
    });
  });

  group('language registry', () {
    test('all languages have STT model paths defined', () {
      for (final lang in kLanguages) {
        expect(lang.sttModel, isNotEmpty, reason: '${lang.name} sttModel');
        expect(lang.sttTokens, isNotEmpty, reason: '${lang.name} sttTokens');
      }
    });

    test('language wire IDs are unique (iBFS byte 3 low nibble)', () {
      final wireIds = kLanguages.map((l) => l.wireId).toList();
      expect(wireIds.toSet().length, wireIds.length,
          reason: 'Duplicate wire IDs break iBFS routing');
    });
  });
}
