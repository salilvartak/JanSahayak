import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/annotation_result.dart';
import '../models/conversation_history.dart';
import '../services/api_service.dart';
import '../services/azure_speech_service.dart';
import '../services/device_service.dart';
import '../services/history_service.dart';

class ConversationScreen extends StatefulWidget {
  final File? initialImageFile;
  final String? initialQuery;
  final String initialLanguage;
  final ConversationHistory? resumeConversation;

  const ConversationScreen.newConversation({
    super.key,
    required this.initialImageFile,
    required this.initialQuery,
    this.initialLanguage = 'en-IN',
  }) : resumeConversation = null;

  const ConversationScreen.resume({
    super.key,
    required this.resumeConversation,
  })  : initialImageFile = null,
        initialQuery = null,
        initialLanguage = 'en-IN';

  bool get isResumeMode => resumeConversation != null;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final ApiService _api = ApiService();
  final AzureSpeechService _azure = AzureSpeechService();
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _recorder = AudioRecorder();
  final ScrollController _scrollCtrl = ScrollController();

  CameraController? _cameraController;

  late final String _conversationId;
  late final DateTime _conversationCreatedAt;
  final List<ConversationTurn> _turns = [];
  final List<_ChatEntry> _chat = [];

  File? _selectedImageForNextTurn;
  AnnotationResult? _lastResult;
  late String _language;

  bool _processing = true;
  bool _listening = false;
  bool _startVoiceInputPending = false;
  bool _transcribing = false;
  bool _cameraFlowActive = false;
  String _pendingVoicePrompt = '';
  int? _playingAudioChatIndex;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.resumeConversation?.id ?? const Uuid().v4();
    _conversationCreatedAt =
        widget.resumeConversation?.createdAt ?? DateTime.now();
    _language = widget.initialLanguage;
    _init();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[ConvScreen] Camera init error: $e');
    }
  }

  Future<void> _init() async {
    await _tts.setSharedInstance(true);
    await _tts.setSpeechRate(0.65);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _playingAudioChatIndex = null);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _playingAudioChatIndex = null);
    });

    if (widget.isResumeMode) {
      ConversationHistory c = widget.resumeConversation!;
      
      try {
        final remoteSource = await _api.getConversation(c.id);
        if (remoteSource != null) {
          // Keep local sessionId if remote is empty since we don't persist it in DB
          c = remoteSource.copyWith(
            sessionId: remoteSource.sessionId.isEmpty ? c.sessionId : null,
          );
          await HistoryService.upsert(c);
        }
      } catch (e) {
        debugPrint('[ConvScreen] Error pulling history from Supabase: $e');
      }

      _turns.addAll(c.turns);
      if (c.previewImageUrl.isNotEmpty) {
        _chat.add(_ChatEntry.imageFromNetwork(c.previewImageUrl, false));
      }
      for (final t in c.turns) {
        _chat.add(_ChatEntry.text(t.text, t.role == 'user'));
      }
      _lastResult = AnnotationResult(
        sessionId: c.sessionId,
        conversationId: c.id,
        needsClarification: false,
        clarificationQuestion: '',
        deviceId: c.deviceId,
        isNewDevice: false,
        queryId: '',
        imageId: '',
        originalUrl: '',
        annotatedUrl: c.previewImageUrl,
        detectedObjects: const [],
        annotatedImageBase64: '',
        explanation: '',
      );
      if (mounted) setState(() => _processing = false);
      _scrollToBottom();
      return;
    }

    await _runAnnotate(
      widget.initialImageFile!,
      widget.initialQuery!,
      firstRun: true,
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _tts.stop();
    _recorder.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _runAnnotate(File image, String query, {bool firstRun = false}) async {
    setState(() {
      _processing = true;
      _chat.add(_ChatEntry.imageFromFile(image, true));
      _chat.add(_ChatEntry.text(query, true));
      _turns.add(
        ConversationTurn(role: 'user', text: query, createdAt: DateTime.now()),
      );
    });
    _scrollToBottom();

    try {
      final deviceId = await DeviceService.getDeviceId();
      final result = await _api.annotate(
        imageFile: image,
        query: query,
        deviceId: deviceId,
        conversationId: _conversationId,
        language: _language,
      );

      if (result.isNewDevice) {
        await DeviceService.updateDeviceId(result.deviceId);
      }

      if (result.needsClarification) {
        setState(() {
          _lastResult = result;
          _chat.add(_ChatEntry.text(result.clarificationQuestion, false));
          _turns.add(
            ConversationTurn(
              role: 'assistant',
              text: result.clarificationQuestion,
              createdAt: DateTime.now(),
            ),
          );
          _processing = false;
        });
        await _speak(result.clarificationQuestion);
      } else {
        setState(() {
          _lastResult = result;
          final img = _decodeImage(result.annotatedImageBase64);
          if (img != null) {
            _chat.add(_ChatEntry.imageFromBytes(img, false));
          }
          _chat.add(_ChatEntry.text(result.explanation, false));
          _turns.add(
            ConversationTurn(
              role: 'assistant',
              text: result.explanation,
              createdAt: DateTime.now(),
            ),
          );
          _processing = false;
        });
        await _speak(result.explanation);
      }
      await _saveHistory();
    } catch (e, st) {
      debugPrint('[ConversationScreen] _runAnnotation error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _processing = false;
        _chat.add(_ChatEntry.text('Something went wrong. Try again.', false));
        _turns.add(
          ConversationTurn(
            role: 'assistant',
            text: 'Something went wrong. Try again.',
            createdAt: DateTime.now(),
          ),
        );
      });
    }

    if (firstRun && mounted) _scrollToBottom();
  }

  Future<void> _runFollowUp(String prompt) async {
    final current = _lastResult;
    if (current == null) return;

    setState(() {
      _processing = true;
      if (_selectedImageForNextTurn != null) {
        _chat.add(_ChatEntry.imageFromFile(_selectedImageForNextTurn!, true));
      }
      _chat.add(_ChatEntry.text(prompt, true));
      _turns.add(
        ConversationTurn(role: 'user', text: prompt, createdAt: DateTime.now()),
      );
    });
    _scrollToBottom();

    try {
      final deviceId = await DeviceService.getDeviceId();
      AnnotationResult result;

      if (_selectedImageForNextTurn != null) {
        result = await _api.annotate(
          imageFile: _selectedImageForNextTurn!,
          query: prompt,
          deviceId: deviceId,
          conversationId: _conversationId,
          language: _language,
        );
      } else {
        result = await _api.clarify(
          sessionId: current.sessionId,
          answer: prompt,
          deviceId: deviceId,
          conversationId: _conversationId,
          language: _language,
        );
      }

      if (!mounted) return;
      setState(() {
        _lastResult = result;
        if (!result.needsClarification) {
          final img = _decodeImage(result.annotatedImageBase64);
          if (img != null) {
            _chat.add(_ChatEntry.imageFromBytes(img, false));
          }
        }
        _chat.add(
          _ChatEntry.text(
            result.needsClarification
                ? result.clarificationQuestion
                : result.explanation,
            false,
          ),
        );
        _turns.add(
          ConversationTurn(
            role: 'assistant',
            text: result.needsClarification
                ? result.clarificationQuestion
                : result.explanation,
            createdAt: DateTime.now(),
          ),
        );
        _selectedImageForNextTurn = null;
        _processing = false;
      });
      await _speak(
        result.needsClarification ? result.clarificationQuestion : result.explanation,
      );
      await _saveHistory();
      HapticFeedback.selectionClick();
    } catch (_) {
      HapticFeedback.vibrate();
      if (!mounted) return;
      setState(() {
        _processing = false;
        _chat.add(_ChatEntry.text('Unable to process this request.', false));
        _turns.add(
          ConversationTurn(
            role: 'assistant',
            text: 'Unable to process this request.',
            createdAt: DateTime.now(),
          ),
        );
      });
    }
    _scrollToBottom();
  }

  Uint8List? _decodeImage(String b64) {
    final raw = b64.replaceFirst(RegExp(r'^data:image/[^;]+;base64,'), '');
    if (raw.isEmpty) return null;
    return base64Decode(raw);
  }

  Future<void> _speak(String text) async {
    if (text.trim().isEmpty) return;
    await _tts.setLanguage(_detectLanguage(text));
    await _tts.speak(text);
  }

  String _detectLanguage(String text) {
    if (text.contains(RegExp(r'[\u0900-\u097F]'))) return _language.startsWith('mr') ? 'mr-IN' : 'hi-IN';
    if (text.contains(RegExp(r'[\u0C00-\u0C7F]'))) return 'te-IN'; // Telugu
    if (text.contains(RegExp(r'[\u0B80-\u0BFF]'))) return 'ta-IN'; // Tamil
    if (text.contains(RegExp(r'[\u0600-\u06FF]'))) return 'ur-PK'; // Urdu
    return 'en-IN';
  }

  Future<void> _startVoiceInput() async {
    if (_processing || !_startVoiceInputPending) return;
    
    try {
      if (!await _recorder.hasPermission()) {
        _startVoiceInputPending = false;
        return;
      }
      
      if (!_startVoiceInputPending) return;
      
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/conv_${DateTime.now().millisecondsSinceEpoch}.wav';
      
      if (!_startVoiceInputPending) return;
      
      setState(() {
        _listening = true;
        _pendingVoicePrompt = '';
      });
      
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      debugPrint('[ConvScreen] Start recording error: $e');
      if (mounted) {
        setState(() {
          _listening = false;
          _cameraFlowActive = false;
          _startVoiceInputPending = false;
        });
      }
    }
  }

  Future<void> _beginMicHold() async {
    if (_processing || _transcribing || _listening) return;
    _startVoiceInputPending = true;
    HapticFeedback.lightImpact();
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100)); // slightly reduced
    
    if (!_startVoiceInputPending) return;
    await _startVoiceInput();
  }

  Future<void> _endMicHold() async {
    final wasListening = _listening;
    _startVoiceInputPending = false;
    
    if (!_listening) {
      if (mounted) setState(() => _listening = false);
      return;
    }
    
    try {
      final audioPath = await _recorder.stop();
      if (mounted) {
        setState(() {
          _listening = false;
          if (audioPath != null) {
            _transcribing = true;
          }
        });
      }

      if (wasListening) {
        HapticFeedback.mediumImpact();
      }

      if (audioPath != null) {
        await _stopVoiceInput(preRecordedPath: audioPath, autoSend: true);
      }
    } catch (e) {
      debugPrint('[ConvScreen] Stop recording error: $e');
      if (mounted) {
        setState(() {
          _listening = false;
          _transcribing = false;
        });
      }
    }
  }

  Future<void> _beginCameraMicHold() async {
    if (_processing || _transcribing || _listening || _cameraFlowActive) return;
    _startVoiceInputPending = true;
    HapticFeedback.lightImpact();
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100)); // slightly reduced

    if (!_startVoiceInputPending) return;

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      await _initCamera();
    }
    
    if (mounted) {
      setState(() {
        _cameraFlowActive = true;
      });
    }
    await _startVoiceInput();
  }

  Future<void> _endCameraMicHold() async {
    final wasActive = _cameraFlowActive;
    final wasListening = _listening;
    _startVoiceInputPending = false;
    
    if (!wasActive) return;
    
    String? audioPath;
    if (wasListening) {
      try {
        audioPath = await _recorder.stop();
      } catch (e) {
        debugPrint('[ConvScreen] Camera stop recording error: $e');
      }
    }

    if (mounted) {
      setState(() {
        _listening = false;
        _cameraFlowActive = false;
        if (audioPath != null) {
          _transcribing = true;
        }
      });
    }
    
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        HapticFeedback.heavyImpact();
        final image = await _cameraController!.takePicture();
        _selectedImageForNextTurn = File(image.path);
      } catch (e) {
        debugPrint('[ConvScreen] Error taking picture: $e');
      }
    }
    
    if (audioPath != null) {
      await _stopVoiceInput(preRecordedPath: audioPath, autoSend: true);
    } else {
      if (mounted) {
        setState(() {
          _listening = false;
          _cameraFlowActive = false;
          _transcribing = false;
        });
      }
    }
  }

  Future<void> _stopVoiceInput({String? preRecordedPath, bool autoSend = true}) async {
    final path = preRecordedPath ?? await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _transcribing = true;
    });

    if (path != null) {
      try {
        final result = await _azure.recognize(path);
        if (mounted && result.transcript.trim().isNotEmpty) {
          setState(() {
            _pendingVoicePrompt = result.transcript.trim();
            _language = result.language; // update so clarify/annotate uses detected language
          });
        }
      } catch (e) {
        debugPrint('[ConvScreen] Azure error: $e');
      }
    }
    if (mounted) {
      setState(() {
        _transcribing = false;
      });
    }

    // Voice-first flow: auto-send after hold release.
    if (autoSend &&
        !_processing &&
        !_transcribing &&
        (_pendingVoicePrompt.trim().isNotEmpty ||
            _selectedImageForNextTurn != null)) {
      await _sendVoicePrompt();
    }
  }

  Future<void> _sendVoicePrompt() async {
    final text = _pendingVoicePrompt.trim();
    if (_processing) return;

    // Allow image-only follow-up even if no voice captured.
    final query = text.isEmpty ? 'Describe what you see' : text;

    setState(() => _pendingVoicePrompt = '');
    await _runFollowUp(query);
  }

  Future<void> _saveHistory() async {
    final result = _lastResult;
    if (result == null) return;
    final now = DateTime.now();
    final history = ConversationHistory(
      id: _conversationId,
      sessionId: result.sessionId,
      deviceId: result.deviceId,
      previewImageUrl: result.annotatedUrl,
      createdAt: _conversationCreatedAt,
      updatedAt: now,
      turns: List<ConversationTurn>.from(_turns),
    );
    await HistoryService.upsert(history);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _toggleBubbleAudio(int index, String text) async {
    if (text.trim().isEmpty) return;
    if (_playingAudioChatIndex == index) {
      await _tts.stop();
      if (mounted) setState(() => _playingAudioChatIndex = null);
      return;
    }
    await _tts.stop();
    if (mounted) setState(() => _playingAudioChatIndex = index);
    await _speak(text);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF07191D),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF07191D), Color(0xFF031015)],
          ),
        ),
        child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  ),
                  Expanded(
                    child: Center(
                      child: Image.asset(
                        'assets/Images/Jansahayak_logo.png',
                        height: 38,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  Text(
                    _topRightTimeDate(),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(children: [
                ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                  itemCount: _chat.length + ((_processing || _transcribing) ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= _chat.length) return _processingBubble();
                    final item = _chat[i];
                    if (item.kind == _ChatEntryKind.image) {
                      return _imageBubble(item);
                    }
                    return _audioBubble(
                      text: item.text!,
                      user: item.isUser,
                      index: i,
                    );
                  },
                ),
                if (_cameraFlowActive &&
                    _cameraController?.value.isInitialized == true)
                  Center(
                    child: FractionallySizedBox(
                      widthFactor: 0.75,
                      heightFactor: 0.75,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  ),
              ]),
            ),
            BottomAppBar(
              color: Colors.black26,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: Listener(
                        onPointerDown: (_) => _beginCameraMicHold(),
                        onPointerUp: (_) => _endCameraMicHold(),
                        child: FilledButton(
                          onPressed: () {}, // Enabled to allow robust gesture catch
                          style: FilledButton.styleFrom(
                            backgroundColor: (_cameraFlowActive || _listening)
                                ? const Color(0xFF2E7D32)
                                : (_selectedImageForNextTurn != null
                                    ? const Color(0xFF2E7D32)
                                    : cs.primary),
                            foregroundColor: cs.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Icon(
                            (_cameraFlowActive || _listening)
                                ? Icons.photo_camera_rounded
                                : (_selectedImageForNextTurn != null
                                    ? Icons.camera_alt_rounded
                                    : Icons.add_a_photo_rounded),
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: Listener(
                        onPointerDown: (_) => _beginMicHold(),
                        onPointerUp: (_) => _endMicHold(),
                        child: FilledButton.tonal(
                          onPressed: () {}, // Enabled to allow robust gesture catch
                          style: FilledButton.styleFrom(
                            backgroundColor: _listening
                                ? cs.errorContainer
                                : cs.secondaryContainer,
                            foregroundColor: _listening
                                ? cs.onErrorContainer
                                : cs.onSecondaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Icon(
                            _listening
                                ? Icons.stop_circle_rounded
                                : Icons.mic_rounded,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  Widget _audioBubble({
    required String text,
    required bool user,
    required int index,
  }) {
    // Basic parser for follow-up suggestions like "1) Suggestion..."
    final List<String> suggestions = [];
    String mainText = text;
    if (!user) {
      final parts = text.split(RegExp(r'\d\)\s+'));
      if (parts.length > 1) {
        mainText = parts[0].trim();
        for (int i = 1; i < parts.length; i++) {
          suggestions.add(parts[i].trim());
        }
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: user
                  ? const Color(0xCC0092A2)
                  : const Color(0xFF1B2B30),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(user ? 20 : 4),
                bottomRight: Radius.circular(user ? 4 : 20),
              ),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!user)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          mainText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.4,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Content reported for review.')),
                          );
                        },
                        icon: const Icon(Icons.outlined_flag_rounded, color: Colors.white24, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                if (!user) const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      onPressed: () => _toggleBubbleAudio(index, text),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        _playingAudioChatIndex == index
                            ? Icons.pause_circle_rounded
                            : Icons.play_circle_rounded,
                      ),
                      color: user ? Colors.white : Colors.tealAccent,
                      iconSize: 42,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _AudioWaveGraphic(
                        active: _playingAudioChatIndex == index,
                        color: user ? Colors.cyanAccent : Colors.tealAccent,
                      ),
                    ),
                  ],
                ),
                if (user) ...[
                  const SizedBox(height: 8),
                  Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!user && suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: suggestions.map((s) {
                return ActionChip(
                  label: Text(s),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _runFollowUp(s);
                  },
                  backgroundColor: const Color(0xFF0D1C21),
                  labelStyle: const TextStyle(
                    color: Color(0xFF5FA6A6),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  side: const BorderSide(color: Color(0xFF1A3A40)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _processingBubble() {
    final cs = Theme.of(context).colorScheme;
    final statusText = _processing ? 'Processing...' : 'Detecting language...';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              statusText,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageBubble(_ChatEntry item) {
    final image = item.bytes != null
        ? Image.memory(item.bytes!, fit: BoxFit.cover)
        : item.file != null
            ? Image.file(item.file!, fit: BoxFit.cover)
            : CachedNetworkImage(
                imageUrl: item.networkUrl!,
                fit: BoxFit.cover,
              );
    return Align(
      alignment: item.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _openImageViewer(item),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          width: 230,
          height: 230,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12, width: 1),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              const Positioned(
                right: 8,
                bottom: 8,
                child: Icon(Icons.open_in_full_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openImageViewer(_ChatEntry item) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            InteractiveViewer(
              child: item.bytes != null
                  ? Image.memory(item.bytes!, fit: BoxFit.contain)
                  : item.file != null
                      ? Image.file(item.file!, fit: BoxFit.contain)
                      : CachedNetworkImage(
                          imageUrl: item.networkUrl!,
                          fit: BoxFit.contain,
                        ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _topRightTimeDate() {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final mo = now.month.toString().padLeft(2, '0');
    return '$hh:$mm   $dd/$mo/${now.year}';
  }
}

enum _ChatEntryKind { text, image }

class _ChatEntry {
  final _ChatEntryKind kind;
  final bool isUser;
  final String? text;
  final File? file;
  final String? networkUrl;
  final Uint8List? bytes;

  const _ChatEntry._({
    required this.kind,
    required this.isUser,
    this.text,
    this.file,
    this.networkUrl,
    this.bytes,
  });

  factory _ChatEntry.text(String text, bool isUser) => _ChatEntry._(
        kind: _ChatEntryKind.text,
        isUser: isUser,
        text: text,
      );

  factory _ChatEntry.imageFromFile(File file, bool isUser) => _ChatEntry._(
        kind: _ChatEntryKind.image,
        isUser: isUser,
        file: file,
      );

  factory _ChatEntry.imageFromNetwork(String url, bool isUser) => _ChatEntry._(
        kind: _ChatEntryKind.image,
        isUser: isUser,
        networkUrl: url,
      );

  factory _ChatEntry.imageFromBytes(Uint8List bytes, bool isUser) => _ChatEntry._(
        kind: _ChatEntryKind.image,
        isUser: isUser,
        bytes: bytes,
      );
}

class _AudioWaveGraphic extends StatefulWidget {
  final bool active;
  final Color color;

  const _AudioWaveGraphic({
    required this.active,
    required this.color,
  });

  @override
  State<_AudioWaveGraphic> createState() => _AudioWaveGraphicState();
}

class _AudioWaveGraphicState extends State<_AudioWaveGraphic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _AudioWaveGraphic oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(28, (i) {
              final phase = (_controller.value + i * 0.06) % 1.0;
              final amp = widget.active
                  ? (0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2))
                  : 0.22;
              return Container(
                width: 3,
                height: 6 + 20 * amp,
                decoration: BoxDecoration(
                  color: widget.active ? widget.color : widget.color.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
