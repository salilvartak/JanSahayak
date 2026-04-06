import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/env_config.dart';
import '../models/annotation_result.dart';
import '../models/conversation_history.dart';
import '../models/transcription_result.dart';
import '../utils/log.dart';

class ApiService {
  static final ApiService _instance = ApiService._();
  factory ApiService() => _instance;

  late final Dio _dio;

  ApiService._() {
    _dio = Dio(
      BaseOptions(
        baseUrl: EnvConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 300),
        headers: {'Accept': 'application/json'},
      ),
    );

    _dio.interceptors.add(_RetryInterceptor(_dio));

    if (kDebugMode) {
      _dio.interceptors.add(LogInterceptor(
        requestBody: false,
        responseBody: false,
        logPrint: (o) => Log.d('HTTP', o.toString()),
      ));
    }
  }

  // ── Annotate ──────────────────────────────────────────────────────────────

  Future<AnnotationResult> annotate({
    required File imageFile,
    required String query,
    required String deviceId,
    String? conversationId,
    String language = 'en-IN',
  }) async {
    final formData = FormData.fromMap({
      'image': await MultipartFile.fromFile(imageFile.path, filename: 'image.jpg'),
      'query': query,
      'device_id': deviceId,
      if (conversationId != null && conversationId.isNotEmpty)
        'conversation_id': conversationId,
      'language': language,
    });

    final response = await _dio.post<Map<String, dynamic>>('/annotate', data: formData);
    return AnnotationResult.fromJson(response.data!);
  }

  // ── Clarify ───────────────────────────────────────────────────────────────

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

  // ── Transcribe ────────────────────────────────────────────────────────────

  Future<TranscriptionResult> transcribe({required File audioFile}) async {
    final formData = FormData.fromMap({
      'audio': await MultipartFile.fromFile(audioFile.path, filename: 'speech.wav'),
    });
    final response = await _dio.post<Map<String, dynamic>>('/transcribe', data: formData);
    return TranscriptionResult.fromJson(response.data!);
  }

  // ── Conversation ──────────────────────────────────────────────────────────

  Future<ConversationHistory?> getConversation(String conversationId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/conversation/$conversationId',
      );
      if (response.statusCode == 200 && response.data != null) {
        return ConversationHistory.fromJson(response.data!);
      }
    } catch (e) {
      Log.e('ApiService', 'getConversation failed', e);
    }
    return null;
  }

  // ── History ───────────────────────────────────────────────────────────────

  Future<List<ConversationHistory>> getHistory(String deviceId) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/history',
        queryParameters: {'device_id': deviceId},
      );
      if (response.statusCode == 200 && response.data != null) {
        return response.data!
            .map((e) => ConversationHistory.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      Log.e('ApiService', 'getHistory failed', e);
    }
    return [];
  }
}

/// Retries idempotent GET requests and network errors up to [_maxRetries] times
/// with exponential backoff.
class _RetryInterceptor extends Interceptor {
  final Dio _dio;
  static const _maxRetries = 2;

  _RetryInterceptor(this._dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final extra = err.requestOptions.extra;
    final retryCount = (extra['_retryCount'] as int?) ?? 0;

    final isRetriable = err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError ||
        (err.response?.statusCode != null && err.response!.statusCode! >= 500);

    if (isRetriable && retryCount < _maxRetries) {
      extra['_retryCount'] = retryCount + 1;
      final delay = Duration(milliseconds: 500 * (retryCount + 1));
      Log.w('Retry', 'Attempt ${retryCount + 1} after ${delay.inMilliseconds}ms '
          'for ${err.requestOptions.path}');
      await Future.delayed(delay);
      try {
        final response = await _dio.fetch(err.requestOptions);
        return handler.resolve(response);
      } on DioException catch (e) {
        return handler.next(e);
      }
    }
    return handler.next(err);
  }
}
