import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_tts/flutter_tts.dart';

class _TutorialStep {
  final IconData icon;
  final Color iconColor;
  final Map<String, String> localizedText;

  const _TutorialStep({
    required this.icon,
    required this.iconColor,
    required this.localizedText,
  });

  String get text {
    final lang = ui.PlatformDispatcher.instance.locale.languageCode;
    return localizedText[lang] ?? localizedText['en'] ?? '';
  }
}

final List<_TutorialStep> _steps = [
  _TutorialStep(
    icon: Icons.waving_hand_rounded,
    iconColor: const Color(0xFF00FFD1),
    localizedText: {
      'en': "Welcome to Jan Sahayak. I am your visual assistant.",
      'hi': "जन-सहायक में आपका स्वागत है। मैं आपका विज़ुअल असिस्टेंट हूँ।",
      'mr': "जन-सहाय्यक मध्ये आपले स्वागत आहे. मी तुमचा व्हिज्युअल असिस्टंट आहे.",
      'te': "జన-సహాయక్ కు స్వాగతం. నేను మీ విజువల్ అసిస్టెంట్.",
    },
  ),
  _TutorialStep(
    icon: Icons.camera_alt_rounded,
    iconColor: const Color(0xFF00ADB5),
    localizedText: {
      'en': "Point your camera at anything you want to understand.",
      'hi': "अपने कैमरे को किसी भी चीज़ की ओर घुमाएँ जिसे आप समझना चाहते हैं।",
      'mr': "तुम्हाला समजून घ्यायची असलेली गोष्ट कॅमेऱ्याने दाखवा.",
      'te': "మీరు అర్థం చేసుకోవాలనుకుంటున్న దేనివైపైనా మీ కెమెరాను చూపండి.",
    },
  ),
  _TutorialStep(
    icon: Icons.mic_rounded,
    iconColor: const Color(0xFF00FFD1),
    localizedText: {
      'en': "Hold the big button and speak your question. Release to send.",
      'hi': "बड़ा बटन दबाकर रखें और अपना सवाल बोलें। भेजने के लिए छोड़ दें।",
      'mr': "मोठे बटण दाबून धरा आणि तुमचा प्रश्न बोला. पाठवण्यासाठी सोडा.",
      'te': "పెద్ద బటన్ నొక్కి పట్టుకుని మీ ప్రశ్న చెప్పండి. పంపడానికి వదిలేయండి.",
    },
  ),
  _TutorialStep(
    icon: Icons.flash_on_rounded,
    iconColor: Colors.yellowAccent,
    localizedText: {
      'en': "Tap the flash button on the left to turn the light on or off.",
      'hi': "लाइट चालू या बंद करने के लिए बाईं ओर वाला फ्लैश बटन दबाएं।",
      'mr': "लाईट चालू किंवा बंद करण्यासाठी डावीकडील फ्लॅश बटण दाबा.",
      'te': "లైట్‌ను ఆన్ లేదా ఆఫ్ చేయడానికి ఎడమవైపు ఫ్లాష్ బటన్ నొక్కండి.",
    },
  ),
  _TutorialStep(
    icon: Icons.flip_camera_ios_rounded,
    iconColor: const Color(0xFF00ADB5),
    localizedText: {
      'en': "Tap the flip button on the right to switch cameras.",
      'hi': "कैमरा बदलने के लिए दाईं ओर वाला फ्लिप बटन दबाएं।",
      'mr': "कॅमेरा बदलण्यासाठी उजवीकडील फ्लिप बटण दाबा.",
      'te': "కెమెరాలను మార్చడానికి కుడివైపు ఫ్లిప్ బటన్ నొక్కండి.",
    },
  ),
  _TutorialStep(
    icon: Icons.history_rounded,
    iconColor: Colors.tealAccent,
    localizedText: {
      'en': "Your past conversations are saved in the History tab at the bottom.",
      'hi': "आपकी पिछली बातचीत नीचे हिस्ट्री टैब में सुरक्षित हैं।",
      'mr': "तुमचे जुने संवाद खालच्या हिस्ट्री टॅबमध्ये जतन केलेले आहेत.",
      'te': "మీ గత సంభాషణలు దిగువన హిస్టరీ ట్యాబ్‌లో సేవ్ చేయబడ్డాయి.",
    },
  ),
  _TutorialStep(
    icon: Icons.check_circle_rounded,
    iconColor: const Color(0xFF2E7D32),
    localizedText: {
      'en': "You are ready! Tap the green button to start using Jan Sahayak.",
      'hi': "आप तैयार हैं! जन-सहायक इस्तेमाल शुरू करने के लिए हरा बटन दबाएं।",
      'mr': "तुम्ही तयार आहात! जन-सहाय्यक वापरण्यासाठी हिरवे बटण दाबा.",
      'te': "మీరు సిద్ధంగా ఉన్నారు! జన-సహాయక్ ఉపయోగించడం ప్రారంభించడానికి ఆకుపచ్చ బటన్ నొక్కండి.",
    },
  ),
];

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final FlutterTts _tts = FlutterTts();
  int _current = 0;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setSharedInstance(true);
    await _tts.setSpeechRate(0.6);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    Future.delayed(const Duration(milliseconds: 400), _playCurrentStep);
  }

  String _getTtsLang() {
    final code = ui.PlatformDispatcher.instance.locale.languageCode;
    switch (code) {
      case 'hi': return 'hi-IN';
      case 'mr': return 'mr-IN';
      case 'te': return 'te-IN';
      default: return 'en-IN';
    }
  }

  Future<void> _playCurrentStep() async {
    if (_current >= _steps.length) return;
    setState(() => _speaking = true);
    await _tts.stop();
    await _tts.setLanguage(_getTtsLang());
    await _tts.speak(_steps[_current].text);
  }

  void _replay() {
    HapticFeedback.lightImpact();
    _playCurrentStep();
  }

  void _next() {
    HapticFeedback.mediumImpact();
    if (_current < _steps.length - 1) {
      setState(() => _current++);
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
    final step = _steps[_current];
    final isLast = _current == _steps.length - 1;
    final progress = (_current + 1) / _steps.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            colors: [Color(0xFF0F3035), Colors.black],
            radius: 1.2,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Logo
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Opacity(
                  opacity: 0.6,
                  child: Image.asset(
                    'assets/Images/Jansahayak_logo.png',
                    height: 48,
                    fit: BoxFit.contain,
                  ),
                ),
              ),

              // Progress dots
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 48),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation(step.iconColor),
                    minHeight: 4,
                  ),
                ),
              ),

              // Main content area
              Expanded(
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: _StepDisplay(
                      key: ValueKey(_current),
                      step: step,
                      speaking: _speaking,
                    ),
                  ),
                ),
              ),

              // Bottom controls
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Replay
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: IconButton.filled(
                        onPressed: _replay,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF00ADB5),
                        ),
                        icon: const Icon(Icons.replay_rounded, size: 30, color: Colors.white),
                      ),
                    ),
                    // Next / Finish
                    SizedBox(
                      width: 80,
                      height: 80,
                      child: IconButton.filled(
                        onPressed: _next,
                        style: IconButton.styleFrom(
                          backgroundColor: isLast
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFF00ADB5),
                        ),
                        icon: Icon(
                          isLast ? Icons.check_rounded : Icons.arrow_forward_rounded,
                          size: 38,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    // Close (skip)
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: IconButton.filled(
                        onPressed: _finish,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white12,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 30, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepDisplay extends StatelessWidget {
  final _TutorialStep step;
  final bool speaking;

  const _StepDisplay({
    super.key,
    required this.step,
    required this.speaking,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Glowing icon
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: step.iconColor.withValues(alpha: speaking ? 0.4 : 0.15),
                    blurRadius: speaking ? 50 : 25,
                    spreadRadius: speaking ? 30 : 8,
                  ),
                ],
              ),
            ).animate(onPlay: (c) => c.repeat(reverse: true))
             .scale(begin: const Offset(1, 1), end: const Offset(1.08, 1.08), duration: 1800.ms),
            Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    step.iconColor,
                    step.iconColor.withValues(alpha: 0.6),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Icon(step.icon, size: 72, color: Colors.white),
            ).animate().fadeIn(duration: 300.ms).scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1), duration: 300.ms),
          ],
        ),
        const SizedBox(height: 32),
        // Speaking indicator
        AnimatedOpacity(
          opacity: speaking ? 1.0 : 0.3,
          duration: const Duration(milliseconds: 300),
          child: Icon(
            speaking ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            color: Colors.white38,
            size: 28,
          ),
        ),
      ],
    );
  }
}
