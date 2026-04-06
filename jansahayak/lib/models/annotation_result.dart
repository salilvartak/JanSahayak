/// Strongly-typed response from POST /annotate or POST /clarify.
class AnnotationResult {
  final String sessionId;
  final String conversationId;
  final bool needsClarification;
  final String clarificationQuestion;  // non-empty when needsClarification=true

  final String deviceId;
  final bool isNewDevice;
  // Fields below are only populated when needsClarification=false
  final String queryId;
  final String imageId;
  final String originalUrl;
  final String annotatedUrl;
  final List<String> detectedObjects;
  final String annotatedImageBase64;   // "data:image/jpeg;base64,..."
  final String explanation;            // spoken aloud to user

  const AnnotationResult({
    required this.sessionId,
    required this.conversationId,
    required this.needsClarification,
    required this.clarificationQuestion,
    required this.deviceId,
    required this.isNewDevice,
    required this.queryId,
    required this.imageId,
    required this.originalUrl,
    required this.annotatedUrl,
    required this.detectedObjects,
    required this.annotatedImageBase64,
    required this.explanation,
  });

  factory AnnotationResult.fromJson(Map<String, dynamic> json) =>
      AnnotationResult(
        sessionId: (json['session_id'] as String?) ?? '',
        conversationId: (json['conversation_id'] as String?) ?? '',
        needsClarification: (json['needs_clarification'] as bool?) ?? false,
        clarificationQuestion: (json['clarification_question'] as String?) ?? '',
        deviceId: (json['device_id'] as String?) ?? '',
        isNewDevice: (json['is_new_device'] as bool?) ?? false,
        queryId: (json['query_id'] as String?) ?? '',
        imageId: (json['image_id'] as String?) ?? '',
        originalUrl: (json['original_url'] as String?) ?? '',
        annotatedUrl: (json['annotated_url'] as String?) ?? '',
        detectedObjects: (json['detected_objects'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
        annotatedImageBase64: (json['annotated_image_base64'] as String?) ?? '',
        explanation: (json['explanation'] as String?) ?? '',
      );
}
