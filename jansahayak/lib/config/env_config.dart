import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Single source of truth for all environment variables.
///
/// Reads from `.env` (loaded by flutter_dotenv at startup).
/// Falls back to compile-time `--dart-define` overrides, then to safe defaults.
/// All accessors are null-safe — the app never crashes from a missing key.
abstract final class EnvConfig {
  static String get apiBaseUrl =>
      const String.fromEnvironment('API_BASE_URL').isNotEmpty
          ? const String.fromEnvironment('API_BASE_URL')
          : dotenv.env['API_BASE_URL'] ??
              'https://jansahayak-api.azurewebsites.net';

  static String get azureSpeechKey =>
      dotenv.env['AZURE_SPEECH_KEY'] ?? '';

  static String get azureSpeechRegion =>
      dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';

  static bool get hasAzureSpeechCredentials =>
      azureSpeechKey.isNotEmpty;

  /// Call once after `dotenv.load()` to surface missing vars early.
  static void validate() {
    if (!hasAzureSpeechCredentials) {
      debugPrint('[EnvConfig] WARNING: AZURE_SPEECH_KEY is missing — '
          'speech services will fall back to Gemini transcription.');
    }
    if (kDebugMode) {
      debugPrint('[EnvConfig] API_BASE_URL    = $apiBaseUrl');
      debugPrint('[EnvConfig] AZURE_REGION    = $azureSpeechRegion');
      debugPrint('[EnvConfig] AZURE_KEY set?  = $hasAzureSpeechCredentials');
    }
  }
}
