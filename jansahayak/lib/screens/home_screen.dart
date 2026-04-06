import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/azure_speech_service.dart';
import 'conversation_screen.dart';
import 'tutorial_screen.dart';
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

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _isRecording = false;
  bool _isBusy = false;
  bool _cameraError = false;
  String _liveTranscript = '';
  String? _pendingAudioPath;
  Timer? _busyTimeout;

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

    try {
      final allCameras = await availableCameras();
      if (allCameras.isEmpty) {
        if (mounted) setState(() => _cameraError = true);
        return;
      }

      _cameras = [];
      try {
        _cameras.add(allCameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back));
      } catch (_) {}
      try {
        _cameras.add(allCameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front));
      } catch (_) {}
      if (_cameras.isEmpty) _cameras = allCameras;

      await _createCameraController(_cameras.first);
      if (mounted) setState(() => _cameraError = false);
    } catch (e) {
      debugPrint('[HomeScreen] _init error: $e');
      if (mounted) setState(() => _cameraError = true);
    }
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _permissionIcon(Icons.camera_alt_rounded),
                    _permissionIcon(Icons.mic_rounded),
                    _permissionIcon(Icons.shield_rounded),
                  ],
                ),
                const SizedBox(height: 64),
                SizedBox(
                  width: 100,
                  height: 100,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await [Permission.camera, Permission.microphone].request();
                      _init();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      shape: const CircleBorder(),
                    ),
                    child: const Icon(Icons.check_rounded, size: 52, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _permissionIcon(IconData icon) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
      ),
      child: Icon(icon, color: Colors.cyanAccent, size: 40),
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
    try {
      await _camera!.initialize();
      await _camera!.setFlashMode(_flashMode);
      if (mounted) setState(() => _cameraError = false);
    } catch (e) {
      debugPrint('[HomeScreen] Camera init failed: $e');
      if (mounted) setState(() => _cameraError = true);
    }
  }

  @override
  void dispose() {
    _busyTimeout?.cancel();
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
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 100));

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
  }

  void _cancelBusy() {
    _busyTimeout?.cancel();
    if (mounted) {
      setState(() {
        _isBusy = false;
        _liveTranscript = '';
      });
    }
    HapticFeedback.vibrate();
  }

  Future<void> _onHoldEnd() async {
    if (!_isRecording || _isBusy) return;

    final navigator = Navigator.of(context);

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
      _pendingAudioPath = null;
    });

    // Auto-cancel after 15s if STT hangs
    _busyTimeout?.cancel();
    _busyTimeout = Timer(const Duration(seconds: 15), _cancelBusy);

    final String resolvedImagePath = imagePath ?? '';
    if (!mounted || resolvedImagePath.isEmpty) {
      _busyTimeout?.cancel();
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

    _busyTimeout?.cancel();

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

  void _openTutorial() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TutorialScreen()),
    );
  }

  Widget _buildCameraErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 64),
          const SizedBox(height: 24),
          SizedBox(
            width: 72,
            height: 72,
            child: FilledButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() => _cameraError = false);
                _init();
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5FA6A6),
                shape: const CircleBorder(),
              ),
              child: const Icon(Icons.refresh_rounded, size: 36, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    final cs = Theme.of(context).colorScheme;
    final bool cameraReady = cam != null && cam.value.isInitialized;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: _cameraError
          ? _buildCameraErrorState()
          : !cameraReady
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(cam),
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
                              onPressed: _openTutorial,
                              icon: const Icon(Icons.help_outline_rounded, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                                    onPressed: _toggleFlash,
                                    icon: Icon(_flashMode == FlashMode.torch
                                        ? Icons.flash_on_rounded
                                        : Icons.flash_off_rounded),
                                  ),
                                  const SizedBox(width: 14),
                                  GestureDetector(
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
                    if (_isRecording || _liveTranscript.isNotEmpty)
                      Positioned(
                        left: 0, right: 0, bottom: 136,
                        child: Center(
                          child: Card(
                            color: cs.surface.withValues(alpha: 0.9),
                            elevation: 4,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    if (_isBusy)
                      Container(
                        color: Colors.black54,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 24),
                              SizedBox(
                                width: 56,
                                height: 56,
                                child: IconButton.filled(
                                  onPressed: _cancelBusy,
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                  ),
                                  icon: const Icon(Icons.close_rounded, size: 30, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

