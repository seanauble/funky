import 'package:audioplayers/audioplayers.dart';

/// Plays the FUNKY party ring (assets/audio/funky_ring.wav) on a loop while a
/// video call is ringing — for the person calling and the person being called.
class RingService {
  RingService._();

  static final AudioPlayer _player = AudioPlayer();
  static bool _playing = false;

  static Future<void> start({double volume = 1.0}) async {
    if (_playing) return;
    _playing = true;
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(volume);
      await _player.play(AssetSource('audio/funky_ring.wav'));
    } catch (_) {
      // No sound is better than a crash.
      _playing = false;
    }
  }

  static Future<void> stop() async {
    if (!_playing) return;
    _playing = false;
    try {
      await _player.stop();
    } catch (_) {}
  }
}
