import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../services/tutorial_service.dart';

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final FlutterTts _tts = FlutterTts();
  late final List<TutorialScript> _scripts;
  int _currentIndex = 0;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    _scripts = TutorialScript.scripts;
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setSharedInstance(true);
    await _tts.setSpeechRate(0.6);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    
    // Start first step after a short delay
    Future.delayed(const Duration(milliseconds: 500), _playCurrentStep);
  }

  Future<void> _playCurrentStep() async {
    if (_currentIndex >= _scripts.length) return;
    
    final langCode = ui.PlatformDispatcher.instance.locale.languageCode;
    final ttsLang = _getTtsLang(langCode);
    
    setState(() => _speaking = true);
    await _tts.stop();
    await _tts.setLanguage(ttsLang);
    await _tts.speak(_scripts[_currentIndex].text);
  }

  String _getTtsLang(String code) {
    switch (code) {
      case 'hi': return 'hi-IN';
      case 'mr': return 'mr-IN';
      case 'te': return 'te-IN';
      default: return 'en-IN';
    }
  }

  void _onSingleTap() {
    HapticFeedback.lightImpact();
    _playCurrentStep();
  }

  void _onDoubleTap() {
    HapticFeedback.mediumImpact();
    if (_currentIndex < _scripts.length - 1) {
      setState(() {
        _currentIndex++;
      });
      _playCurrentStep();
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    await _tts.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Gradient / Decor
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                colors: [Color(0xFF0F3035), Colors.black],
                radius: 1.2,
              ),
            ),
          ),

          // Central Pulse Orb
          Center(
            child: GestureDetector(
              onTap: _onSingleTap,
              onDoubleTap: _onDoubleTap,
              child: Stack(
                alignment: Alignment.center,
                children: [
                   // Glowing Halo
                  Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _speaking ? Colors.cyan.withValues(alpha: 0.4) : Colors.cyan.withValues(alpha: 0.1),
                          blurRadius: _speaking ? 60 : 30,
                          spreadRadius: _speaking ? 40 : 10,
                        ),
                      ],
                    ),
                  ).animate(onPlay: (controller) => controller.repeat(reverse: true))
                   .scale(begin: const Offset(1, 1), end: const Offset(1.1, 1.1), duration: 2000.ms),

                  // The Orb
                  Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF00FFD1), Color(0xFF00ADB5)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        _speaking ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                        size: 100,
                        color: Colors.white,
                      ),
                    ),
                  ).animate().shimmer(duration: 3.seconds, color: Colors.white24),
                ],
              ),
            ),
          ),

          // Subtle text hints just in case, but user said "no text"
          // So I will only show the logo at top
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Opacity(
                opacity: 0.6,
                child: Image.asset(
                  'assets/Images/Jansahayak_logo.png',
                  height: 60,
                  fit: BoxFit.contain,
                ),
              ),
            ).animate().fadeIn(duration: 1.seconds),
          ),
        ],
      ),
    );
  }
}
