import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Centralised chime player for tactile audio feedback.
///
/// Configured to **not** steal audio focus so it won't interfere with
/// the [AudioRecorder] capturing mic input.
class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  final AudioPlayer _player = AudioPlayer();
  bool _configured = false;

  /// One-time setup: tell the player to avoid stealing audio focus.
  Future<void> _ensureConfigured() async {
    if (_configured) return;
    _configured = true;

    // On Android: don't request audio focus so the mic recorder keeps working.
    // On iOS: mix with others (duckOthers = false) so we don't interrupt
    // the recording audio session.
    await _player.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          audioFocus: AndroidAudioFocus.none,
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationEvent,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      ),
    );

    await _player.setPlayerMode(PlayerMode.lowLatency);
  }

  /// Ascending two-note chime – played when mic recording **starts**.
  Future<void> playStartChime() => _play('sounds/chime_start.wav');

  /// Descending two-note chime – played when mic recording **stops**.
  Future<void> playStopChime() => _play('sounds/chime_stop.wav');

  /// Quick double-click chime – played on camera **shutter**.
  Future<void> playShutterChime() => _play('sounds/chime_shutter.wav');

  Future<void> _play(String assetPath) async {
    try {
      await _ensureConfigured();
      await _player.stop();
      await _player.play(AssetSource(assetPath));
    } catch (e) {
      debugPrint('[SoundService] Error playing $assetPath: $e');
    }
  }

  void dispose() {
    _player.dispose();
  }
}
