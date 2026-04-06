class TranscriptionResult {
  final String transcript;
  final String language;

  const TranscriptionResult({
    required this.transcript,
    required this.language,
  });

  factory TranscriptionResult.fromJson(Map<String, dynamic> json) {
    return TranscriptionResult(
      transcript: (json['transcript'] as String?) ?? '',
      language: (json['language'] as String?) ?? 'unknown',
    );
  }
}
