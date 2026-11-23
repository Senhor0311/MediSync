import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Opt-in only after owner registration and device acceptance. No enforcement
/// or network attestation during emulator tests. No debug provider/token exists.
Future<void> prepareAppAttestation({
  required bool emulator,
  required FirebaseApp app,
}) async {
  const enabled = bool.fromEnvironment('ANDROID_APP_CHECK');
  if (!enabled) return;
  if (emulator ||
      kDebugMode ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    throw StateError(
      'ANDROID_APP_CHECK requires a live Android release with registered Play Integrity. Leave it disabled for emulators and other targets.',
    );
  }
  await FirebaseAppCheck.instanceFor(app: app)
      .activate(providerAndroid: const AndroidPlayIntegrityProvider());
}
