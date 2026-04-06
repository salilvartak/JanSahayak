import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../config/env_config.dart';
import '../utils/log.dart';

class AzureSpeechService {
  static const _tag = 'Azure';

  final String _key = EnvConfig.azureSpeechKey;
  final String _region = EnvConfig.azureSpeechRegion;

  bool get available => _key.isNotEmpty;

  static const _candidateLanguages = ['hi-IN', 'mr-IN', 'te-IN', 'ta-IN', 'en-US'];

  // If the best Indian-language confidence is within this margin of en-US,
  // prefer the Indian language.  Prevents Roman-script Hindi from
  // beating Devanagari Hindi by a tiny float gap.
  static const double _tieThreshold = 0.10;

  String? _token;
  DateTime? _tokenExpiry;

  Future<String> _getToken() async {
    if (_token != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _token!;
    }

    final url =
        'https://$_region.api.cognitive.microsoft.com/sts/v1.0/issueToken';
    Log.d(_tag, 'Fetching token from $url');

    final response = await http.post(
      Uri.parse(url),
      headers: {'Ocp-Apim-Subscription-Key': _key},
    );

    if (response.statusCode == 200) {
      _token = response.body;
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
      Log.d(_tag, 'Token obtained');
      return _token!;
    }
    throw Exception(
        'Azure token error ${response.statusCode}: ${response.body}');
  }

  Future<({String language, String transcript, double confidence})?>
      _tryLanguage(String token, List<int> audioBytes, String lang) async {
    final url =
        'https://$_region.stt.speech.microsoft.com/speech/recognition/'
        'conversation/cognitiveservices/v1'
        '?language=$lang&format=detailed';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'audio/wav',
          'Accept': 'application/json',
        },
        body: audioBytes,
      );

      Log.d(_tag, '[$lang] HTTP ${response.statusCode}');

      if (response.statusCode != 200) return null;

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final status = result['RecognitionStatus'] ?? 'Unknown';
      final transcript = result['DisplayText'] as String? ?? '';

      double confidence = 0.0;
      final nBest = result['NBest'] as List<dynamic>?;
      if (nBest != null && nBest.isNotEmpty) {
        confidence = (nBest.first['Confidence'] as num?)?.toDouble() ?? 0.0;
      }

      Log.d(_tag, '[$lang] status=$status '
          'confidence=${confidence.toStringAsFixed(3)} "$transcript"');

      if (status != 'Success' || transcript.isEmpty) return null;
      return (language: lang, transcript: transcript, confidence: confidence);
    } catch (e) {
      Log.e(_tag, '[$lang] Exception', e);
      return null;
    }
  }

  /// Transcribes a WAV file using Azure Cognitive Speech.
  /// Returns empty transcript if credentials are missing (fail-safe).
  Future<({String transcript, String language})> recognize(
      String wavPath) async {
    if (!available) {
      Log.w(_tag, 'No AZURE_SPEECH_KEY — returning empty transcript');
      return (transcript: '', language: 'hi-IN');
    }

    Log.d(_tag, 'recognize($wavPath)');

    final audioFile = File(wavPath);
    if (!audioFile.existsSync()) {
      throw Exception('Audio file not found: $wavPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    Log.d(_tag, 'File size: ${audioBytes.length} bytes');

    final token = await _getToken();

    final futures = _candidateLanguages
        .map((lang) => _tryLanguage(token, audioBytes, lang))
        .toList();

    final results = await Future.wait(futures, eagerError: false);

    final valid = results
        .whereType<({String language, String transcript, double confidence})>()
        .toList();

    double maxConfidence =
        valid.fold(-1.0, (m, r) => r.confidence > m ? r.confidence : m);

    final tieGroup = valid
        .where((r) => r.confidence >= maxConfidence - _tieThreshold)
        .toList();

    Log.d(_tag, 'tieGroup: '
        '${tieGroup.map((r) => '${r.language}=${r.confidence.toStringAsFixed(3)}').join(', ')}');

    ({String language, String transcript, double confidence})? winner;
    for (final lang in _candidateLanguages) {
      winner = tieGroup.where((r) => r.language == lang).firstOrNull;
      if (winner != null) break;
    }
    winner ??= valid.isNotEmpty ? valid.first : null;

    final bestTranscript = winner?.transcript ?? '';
    final bestLanguage = winner?.language ?? 'hi-IN';

    Log.d(_tag, 'Winner: $bestLanguage "$bestTranscript"');

    return (transcript: bestTranscript, language: bestLanguage);
  }
}
