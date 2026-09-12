import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Sets up the kiosk behaviour from §4.9: immersive fullscreen, keep-awake,
/// and (best-effort) Android Lock Task Mode. Every step is independently
/// wrapped so a failure in one (an unsupported device, a missing platform
/// channel) can never block startup or take the others down with it.
///
/// The landscape-only orientation lock §4.9 originally specified is
/// overridden by SPEC-RESPONSIVE.md §1 — all four orientations are allowed
/// so the layout can adapt instead.
class KioskService {
  KioskService._();

  static const _channel = MethodChannel('com.codestation23.feedback/kiosk');

  static Future<void> enable() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}

    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (_) {}

    try {
      await WakelockPlus.enable();
    } catch (_) {}

    try {
      await _channel.invokeMethod('enterKioskMode');
    } catch (_) {}
  }
}
