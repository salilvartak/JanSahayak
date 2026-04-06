class ConversationTurn {
  final String role; // user | assistant
  final String text;
  final DateTime createdAt;

  const ConversationTurn({
    required this.role,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'created_at': createdAt.toIso8601String(),
      };

  factory ConversationTurn.fromJson(Map<String, dynamic> json) {
    return ConversationTurn(
      role: (json['role'] as String?) ?? 'assistant',
      text: (json['text'] as String?) ?? '',
      createdAt: DateTime.tryParse((json['created_at'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}

class ConversationHistory {
  final String id;
  final String sessionId;
  final String deviceId;
  final String previewImageUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ConversationTurn> turns;

  const ConversationHistory({
    required this.id,
    required this.sessionId,
    required this.deviceId,
    required this.previewImageUrl,
    required this.createdAt,
    required this.updatedAt,
    required this.turns,
  });

  String get title {
    final userTurns = turns.where((t) => t.role == 'user');
    final firstUser = userTurns.isEmpty ? null : userTurns.first;
    if (firstUser == null || firstUser.text.trim().isEmpty) {
      return 'Conversation';
    }
    return firstUser.text.trim();
  }

  String get subtitle {
    if (turns.isEmpty) return '';
    return turns.last.text.trim();
  }

  ConversationHistory copyWith({
    String? sessionId,
    String? deviceId,
    String? previewImageUrl,
    DateTime? updatedAt,
    List<ConversationTurn>? turns,
  }) {
    return ConversationHistory(
      id: id,
      sessionId: sessionId ?? this.sessionId,
      deviceId: deviceId ?? this.deviceId,
      previewImageUrl: previewImageUrl ?? this.previewImageUrl,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      turns: turns ?? this.turns,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'session_id': sessionId,
        'device_id': deviceId,
        'preview_image_url': previewImageUrl,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'turns': turns.map((e) => e.toJson()).toList(),
      };

  factory ConversationHistory.fromJson(Map<String, dynamic> json) {
    return ConversationHistory(
      id: (json['id'] as String?) ?? '',
      sessionId: (json['session_id'] as String?) ?? '',
      deviceId: (json['device_id'] as String?) ?? '',
      previewImageUrl: (json['preview_image_url'] as String?) ?? '',
      createdAt: DateTime.tryParse((json['created_at'] as String?) ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse((json['updated_at'] as String?) ?? '') ??
          DateTime.now(),
      turns: ((json['turns'] as List?) ?? [])
          .map((e) => ConversationTurn.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
