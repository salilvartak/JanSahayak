import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'dart:ui' as ui;

import '../services/azure_speech_service.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import '../services/tutorial_service.dart';
import 'conversation_screen.dart';
import 'package:flutter_tts/flutter_tts.dart';

class HomeScreen extends StatefulWidget {
  final bool isActive;
  const HomeScreen({super.key, this.isActive = true});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _camera;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;

  // ── Audio + Azure ─────────────────────────────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
  final AzureSpeechService _azure = AzureSpeechService();
  final FlutterTts _tts = FlutterTts();

  // ── Tutorial Keys ─────────────────────────────────────────────────────────
  final GlobalKey _flashKey = GlobalKey();
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _flipKey = GlobalKey();

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _isRecording = false;
  bool _isBusy = false;
  String _liveTranscript = '';
  String? _pendingImagePath;
  String? _pendingAudioPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.isActive) {
      _init();
    }
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        if (_camera == null || !_camera!.value.isInitialized) {
          _init();
        } else {
          _camera?.resumePreview();
        }
      } else {
        _camera?.pausePreview();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_camera == null || !_camera!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _camera?.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed && widget.isActive) {
      _init();
    }
  }

  Future<void> _init() async {
    final camStat = await Permission.camera.status;
    final micStat = await Permission.microphone.status;

    if (!camStat.isGranted || !micStat.isGranted) {
      if (!mounted) return;
      await _showPermissionDisclosure();
      return;
    }
    
    final allCameras = await availableCameras();
    if (allCameras.isEmpty) return;

    _cameras = [];
    try {
      _cameras.add(allCameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back));
    } catch (_) {}
    try {
      _cameras.add(allCameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front));
    } catch (_) {}
    if (_cameras.isEmpty) _cameras = allCameras;

    await _createCameraController(_cameras.first);
    
    // Play localized welcome message
    _playWelcomeMessage();
  }

  Future<void> _playWelcomeMessage() async {
    final langCode = ui.PlatformDispatcher.instance.locale.languageCode;
    String message;
    String ttsLang;

    switch (langCode) {
      case 'hi':
        message = "नमस्ते, मैं जन-सहायक, आपका व्यक्तिगत एआई असिस्टेंट हूँ।";
        ttsLang = 'hi-IN';
        break;
      case 'mr':
        message = "नमस्कार, मी जन-सहाय्यक, तुमचा वैयक्तिक एआय सहाय्यक आहे.";
        ttsLang = 'mr-IN';
        break;
      case 'te':
        message = "నమస్తే, నేను జన-సహాయక్, మీ వ్యక్తిగత ఏఐ అసిస్టెంట్.";
        ttsLang = 'te-IN';
        break;
      case 'en':
      default:
        message = "Hi, I am Jan Sahayak, your personal A I assistant.";
        ttsLang = 'en-IN';
        break;
    }

    try {
      await _tts.setSharedInstance(true);
      await _tts.setLanguage(ttsLang);
      await _tts.setSpeechRate(0.65);
      await _tts.speak(message);
    } catch (_) {}
  }

  Future<void> _showPermissionDisclosure() async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return Scaffold(
          backgroundColor: const Color(0xFF031015),
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.security_rounded, color: Colors.cyanAccent, size: 80),
                const SizedBox(height: 32),
                const Text(
                  'Privacy & Sensors',
                  style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                const Text(
                  'JanSahayak uses your camera and microphone to "see" and "hear" your queries. \n\nImages and audio are securely processed to provide real-time AI assistance. We do not store your data for any other purpose.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await [Permission.camera, Permission.microphone].request();
                      _init();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('Agree & Continue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _createCameraController(CameraDescription description) async {
    await _camera?.dispose();
    _camera = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _camera!.initialize();
    await _camera!.setFlashMode(_flashMode);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.stop();
    _recorder.dispose();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _isBusy) return;
    HapticFeedback.lightImpact();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _createCameraController(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    if (_camera == null || _isBusy) return;
    HapticFeedback.lightImpact();
    _flashMode = _flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch;
    await _camera!.setFlashMode(_flashMode);
    if (mounted) setState(() {});
  }

  // ── Hold to speak + capture ───────────────────────────────────────────────

  Future<void> _onHoldStart() async {
    if (_isBusy || _camera == null || !_camera!.value.isInitialized) return;

    HapticFeedback.mediumImpact();
    await _tts.stop(); // Stop welcome message if user interrupts
    await Future.delayed(const Duration(milliseconds: 100)); // allow TTS audio focus to release

    setState(() {
      _isRecording = true;
      _liveTranscript = '';
    });

    final dir = await getTemporaryDirectory();
    final audioPath = '${dir.path}/qs_${DateTime.now().millisecondsSinceEpoch}.wav';
    
    setState(() {
      _pendingAudioPath = audioPath;
    });

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: audioPath,
    );
    debugPrint('[HomeScreen] recording started → $audioPath');
  }

  Future<void> _onHoldEnd() async {
    if (!_isRecording || _isBusy) return;

    final navigator = Navigator.of(context);
    
    // Stop recording first before playing chimes/taking picture to dodge audio ducking bugs
    final stoppedPath = await _recorder.stop();
    final audioPath = stoppedPath ?? _pendingAudioPath;

    String? imagePath;
    if (_camera != null && _camera!.value.isInitialized) {
      try {
        final shot = await _camera!.takePicture();
        imagePath = shot.path;
      } catch (e) {
        debugPrint('[HomeScreen] Error taking picture: $e');
      }
    }

    HapticFeedback.heavyImpact();

    setState(() {
      _isRecording = false;
      _isBusy = true;
      _pendingImagePath = null;
      _pendingAudioPath = null;
    });

    final String resolvedImagePath = imagePath ?? '';
    if (!mounted || resolvedImagePath.isEmpty) {
      setState(() => _isBusy = false);
      return;
    }

    String query = 'Describe what you see';
    String language = 'en-IN';

    if (audioPath != null) {
      try {
        final result = await _azure.recognize(audioPath);
        if (result.transcript.trim().isNotEmpty) {
          query = result.transcript.trim();
          language = result.language;
        }
        if (mounted) setState(() => _liveTranscript = query);
      } catch (e) {
        debugPrint('[HomeScreen] Azure error: $e');
      }
    }

    if (!mounted) return;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen.newConversation(
          initialImageFile: File(resolvedImagePath),
          initialQuery: query,
          initialLanguage: language,
        ),
      ),
    );

    if (mounted) {
      setState(() {
        _isBusy = false;
        _liveTranscript = '';
      });
    }
  }

  Future<void> _playTutorialStep(int index) async {
    final scripts = TutorialScript.scripts;
    if (index < 0 || index >= scripts.length) return;
    
    final langCode = ui.PlatformDispatcher.instance.locale.languageCode;
    String ttsLang = 'en-IN';
    switch (langCode) {
      case 'hi': ttsLang = 'hi-IN'; break;
      case 'mr': ttsLang = 'mr-IN'; break;
      case 'te': ttsLang = 'te-IN'; break;
    }
    
    await _tts.stop();
    await _tts.setLanguage(ttsLang);
    await _tts.setSpeechRate(0.6);
    await _tts.speak(scripts[index].text);
  }

  void _startTutorial() {
    _lastPlayedStepIndex = -1; // Reset to ensure audio plays on 1st step
    final scripts = TutorialScript.scripts;
    final List<TargetFocus> targets = [];

    // 1. Welcome + Main Orb
    targets.add(_createTarget('welcome', _micKey, ContentAlign.top, scripts[0]));
    // 2. Camera + Viewport
    targets.add(_createTarget('camera', _micKey, ContentAlign.top, scripts[1])); 
    // 3. Main Orb details
    targets.add(_createTarget('mic', _micKey, ContentAlign.top, scripts[2]));
    // 4. Flash
    targets.add(_createTarget('flash', _flashKey, ContentAlign.top, scripts[3]));
    // 5. Flip
    targets.add(_createTarget('flip', _flipKey, ContentAlign.top, scripts[4]));
    // 6. History
    targets.add(_createTarget('history', _micKey, ContentAlign.top, scripts[5])); // explain history tab
    // 7. Conversation
    targets.add(_createTarget('conversation', _micKey, ContentAlign.top, scripts[6])); // explain conversation flow
    // 8. Finish
    targets.add(_createTarget('finish', _micKey, ContentAlign.top, scripts[7]));

    TutorialCoachMark(
      targets: targets,
      colorShadow: Colors.black,
      opacityShadow: 0.9,
      textSkip: "SKIP",
      onFinish: () => _tts.stop(),
      onClickOverlay: (target) {
         // Optionally block clicks outside orb if needed, but user didn't specify.
      },
    ).show(context: context);
  }

  int _lastPlayedStepIndex = -1;

  TargetFocus _createTarget(String id, GlobalKey key, ContentAlign align, TutorialScript script) {
    return TargetFocus(
      identify: id,
      keyTarget: key,
      alignSkip: Alignment.topRight,
      radius: 20,
      contents: [
        TargetContent(
          align: align,
          builder: (context, controller) {
            final idx = TutorialScript.scripts.indexWhere((s) => s.stepName == id);
            // Only play if this is a new step being shown
            if (_lastPlayedStepIndex != idx) {
              _lastPlayedStepIndex = idx;
              _playTutorialStep(idx);
            }
            return _TutorialOrbController(
              onRepeat: () => _playTutorialStep(idx),
              onNext: () {
                if (id == 'finish') {
                   controller.skip();
                } else {
                   controller.next();
                }
              },
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: cam == null || !cam.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(cam),
                // Top watermark logo
                Positioned(
                  top: 0, left: 16, right: 16,
                  child: SafeArea(
                    child: Row(
                      children: [
                        Opacity(
                          opacity: 0.8,
                          child: Image.asset(
                            'assets/Images/Jansahayak_logo.png',
                            height: 50,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const Spacer(),
                        IconButton.filledTonal(
                          onPressed: _startTutorial,
                          icon: const Icon(Icons.help_outline_rounded, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
                // Bottom controls
                Positioned(
                  left: 0, right: 0, bottom: 22,
                  child: SafeArea(
                    child: Center(
                      child: Card(
                        color: cs.surface.withValues(alpha: 0.9),
                        elevation: 8,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton.filledTonal(
                                key: _flashKey,
                                onPressed: _toggleFlash,
                                icon: Icon(_flashMode == FlashMode.torch
                                    ? Icons.flash_on_rounded
                                    : Icons.flash_off_rounded),
                              ),
                              const SizedBox(width: 14),
                              GestureDetector(
                                key: _micKey,
                                onLongPressStart: (_) => _onHoldStart(),
                                onLongPressEnd: (_) => _onHoldEnd(),
                                onLongPressCancel: _onHoldEnd,
                                child: FloatingActionButton.large(
                                  heroTag: 'hold-mic',
                                  backgroundColor: _isRecording ? cs.error : cs.primary,
                                  foregroundColor: cs.onPrimary,
                                  onPressed: () {},
                                  child: Icon(
                                    _isRecording
                                        ? Icons.graphic_eq_rounded
                                        : Icons.mic_rounded,
                                    size: 38,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              IconButton.filledTonal(
                                key: _flipKey,
                                onPressed: _flipCamera,
                                icon: const Icon(Icons.flip_camera_ios_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Live transcript / recording indicator
                if (_isRecording || _liveTranscript.isNotEmpty)
                  Positioned(
                    left: 0, right: 0, bottom: 136,
                    child: Center(
                      child: Card(
                        color: cs.surface.withValues(alpha: 0.9),
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isRecording
                                    ? Icons.graphic_eq_rounded
                                    : Icons.mic_none_rounded,
                                color: cs.primary,
                                size: 24,
                              ),
                              if (_liveTranscript.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 240),
                                  child: Text(
                                    _liveTranscript,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: cs.onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // Processing overlay (shown while Azure transcribes)
                if (_isBusy)
                  Container(
                    color: Colors.black38,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
    );
  }
}

class _TutorialOrbController extends StatelessWidget {
  final VoidCallback onRepeat;
  final VoidCallback onNext;

  const _TutorialOrbController({required this.onRepeat, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        GestureDetector(
          onTap: onRepeat,
          onDoubleTap: onNext,
          child: Container(
            width: 130,
            height: 130,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF00FFD1), Color(0xFF00ADB5)],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.cyanAccent,
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              size: 60,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '1: Repeat | 2: Next',
          style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 1.5),
        ),
      ],
    );
  }
}
