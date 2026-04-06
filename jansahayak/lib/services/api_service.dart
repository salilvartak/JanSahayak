import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/annotation_result.dart';
import '../models/conversation_history.dart';
import '../models/transcription_result.dart';

/// HTTP client for the JanSahayak FastAPI backend.
///
/// ┌──────────────────────────────────────────────────────────────────────────┐
/// │  BASE URL QUICK-REFERENCE                                                │
/// │  Production  →  https://jansahayak-api.azurewebsites.net                │
/// │  Override    →  --dart-define=API_BASE_URL=http://YOUR_LAN_IP:8000       │
/// └──────────────────────────────────────────────────────────────────────────┘
class ApiService {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://jansahayak-api.azurewebsites.net',
  );

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 180),
    ),
  );

  Future<AnnotationResult> annotate({
    required File imageFile,
    required String query,
    required String deviceId,
    String? conversationId,
    String language = 'en-IN',
  }) async {
    final formData = FormData.fromMap({
      'image': await MultipartFile.fromFile(
        imageFile.path,
        filename: 'image.jpg',
      ),
      'query': query,
      'device_id': deviceId,
      if (conversationId != null && conversationId.isNotEmpty)
        'conversation_id': conversationId,
      'language': language,
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/annotate',
      data: formData,
    );

    return AnnotationResult.fromJson(response.data!);
  }

  Future<AnnotationResult> clarify({
    required String sessionId,
    required String answer,
    required String deviceId,
    String? conversationId,
    String language = 'en-IN',
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/clarify',
      data: {
        'session_id': sessionId,
        'answer': answer,
        'device_id': deviceId,
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_id': conversationId,
        'language': language,
      },
    );

    return AnnotationResult.fromJson(response.data!);
  }

  Future<TranscriptionResult> transcribe({
    required File audioFile,
  }) async {
    final formData = FormData.fromMap({
      'audio': await MultipartFile.fromFile(
        audioFile.path,
        filename: 'speech.wav',
      ),
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/transcribe',
      data: formData,
    );

    return TranscriptionResult.fromJson(response.data!);
  }

  Future<ConversationHistory?> getConversation(String conversationId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/conversation/$conversationId',
      );
      if (response.statusCode == 200 && response.data != null) {
        return ConversationHistory.fromJson(response.data!);
      }
    } catch (e) {
      debugPrint('[ApiService] getConversation error: $e');
    }
    return null;
  }

  Future<List<ConversationHistory>> getHistory(String deviceId) async {
    try {
      debugPrint('[ApiService] Starting GET /history for device: $deviceId');
      final response = await _dio.get<List<dynamic>>(
        '/history',
        queryParameters: {'device_id': deviceId},
      );
      
      debugPrint('[ApiService] GET /history responded with HTTP ${response.statusCode}');
      if (response.statusCode == 200 && response.data != null) {
        debugPrint('[ApiService] Parsing ${response.data!.length} history records...');
        return response.data!
            .map((e) => ConversationHistory.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[ApiService] getHistory error during HTTP call or parsing: $e');
    }
    return [];
  }
}
