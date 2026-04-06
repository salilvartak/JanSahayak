import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AzureSpeechService {
  final _key = dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  final _region = dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';

  // Languages tried in parallel.
  // ORDER MATTERS — this is also the tiebreak priority.
  // Indian languages are listed before English so that when confidence scores
  // are close (within _tieThreshold), the Indian language wins.
  static const _candidateLanguages = ['hi-IN', 'mr-IN', 'te-IN', 'ta-IN', 'en-US'];

  // If the best Indian-language confidence is within this margin of en-US,
  // prefer the Indian language. Prevents Roman-script Hindi ("Yeh kya hai")
  // from beating Devanagari Hindi ("ये क्या है?") by a tiny float gap.
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
    debugPrint('[Azure] Fetching token from $url');

    final response = await http.post(
      Uri.parse(url),
      headers: {'Ocp-Apim-Subscription-Key': _key},
    );

    if (response.statusCode == 200) {
      _token = response.body;
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
      debugPrint('[Azure] Token obtained');
      return _token!;
    }
    throw Exception(
        'Azure token error ${response.statusCode}: ${response.body}');
  }

  Future<({String language, String transcript, double confidence})?>
      _tryLanguage(
          String token, List<int> audioBytes, String lang) async {
    final url =
        'https://$_region.stt.speech.microsoft.com/speech/recognition/'
        'conversation/cognitiveservices/v1'
        '?language=$lang&format=detailed';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          // Send as audio/wav — Azure reads sample rate from the WAV header.
          // Specifying samplerate=16000 in Content-Type when Android records
          // at a different rate causes mismatch and zero-confidence results.
          'Content-Type': 'audio/wav',
          'Accept': 'application/json',
        },
        body: audioBytes,
      );

      debugPrint('  [$lang] HTTP ${response.statusCode} body=${response.body}');

      if (response.statusCode != 200) return null;

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final status = result['RecognitionStatus'] ?? 'Unknown';
      final transcript = result['DisplayText'] as String? ?? '';

      double confidence = 0.0;
      final nBest = result['NBest'] as List<dynamic>?;
      if (nBest != null && nBest.isNotEmpty) {
        confidence = (nBest.first['Confidence'] as num?)?.toDouble() ?? 0.0;
      }

      debugPrint('  [$lang] status=$status '
          'confidence=${confidence.toStringAsFixed(3)} "$transcript"');

      // Filter: empty transcript is useless even if status=Success
      if (status != 'Success' || transcript.isEmpty) return null;

      return (language: lang, transcript: transcript, confidence: confidence);
    } catch (e) {
      debugPrint('  [$lang] Exception: $e');
      return null;
    }
  }

  Future<({String transcript, String language})> recognize(
      String wavPath) async {
    debugPrint('[Azure] recognize($wavPath)');

    final audioFile = File(wavPath);
    if (!audioFile.existsSync()) {
      throw Exception('Audio file not found: $wavPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    debugPrint('[Azure] File size: ${audioBytes.length} bytes');

    final token = await _getToken();

    final futures = _candidateLanguages
        .map((lang) => _tryLanguage(token, audioBytes, lang))
        .toList();

    final results = await Future.wait(futures, eagerError: false);

    // Find the highest confidence across all results
    final valid = results.whereType<({String language, String transcript, double confidence})>().toList();

    double maxConfidence = valid.fold(-1.0, (m, r) => r.confidence > m ? r.confidence : m);

    // Candidates within the tiebreak window of the max score
    final tieGroup = valid.where((r) => r.confidence >= maxConfidence - _tieThreshold).toList();

    debugPrint('[Azure] tieGroup (threshold=$_tieThreshold): '
        '${tieGroup.map((r) => '${r.language}=${r.confidence.toStringAsFixed(3)}').join(', ')}');

    // Pick by priority order (_candidateLanguages is the tiebreak ranking)
    // This ensures "ये क्या है?" (hi-IN 0.661) beats "Yeh kya hai." (en-US 0.663)
    ({String language, String transcript, double confidence})? winner;
    for (final lang in _candidateLanguages) {
      winner = tieGroup.where((r) => r.language == lang).firstOrNull;
      if (winner != null) break;
    }
    winner ??= valid.isNotEmpty ? valid.first : null;

    final bestTranscript = winner?.transcript ?? '';
    final bestLanguage   = winner?.language   ?? 'hi-IN';
    final bestConfidence = winner?.confidence ?? 0.0;

    debugPrint('[Azure] Winner: $bestLanguage '
        '(confidence=${bestConfidence.toStringAsFixed(3)}) '
        '"$bestTranscript"');

    return (transcript: bestTranscript, language: bestLanguage);
  }
}
