import 'package:flutter/foundation.dart';

const firebaseEmulatorAppName = 'medisync-emulator';

String emulatorEmailVerificationCode(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null ||
      uri.scheme != 'http' ||
      !['127.0.0.1', 'localhost'].contains(uri.host) ||
      uri.port != 9099 ||
      uri.path != '/emulator/action' ||
      uri.queryParameters['mode'] != 'verifyEmail' ||
      (uri.queryParameters['oobCode'] ?? '').isEmpty) {
    throw const FormatException(
      'Use the local Auth emulator verification link.',
    );
  }
  return uri.queryParameters['oobCode']!;
}

/// Windows has no auto-initialized default app, which the native Firestore
/// delegate factory requires. Use synthetic options for its default app.
/// Android keeps a separate demo app to avoid bundled default configuration.
String? firebaseInitializationAppName({
  required bool useEmulators,
  required bool isWeb,
  required TargetPlatform platform,
}) => !useEmulators || (!isWeb && platform == TargetPlatform.windows)
    ? null
    : firebaseEmulatorAppName;

Uri? canonicalEmulatorWebOrigin(Uri current) {
  if (current.host == 'localhost' && current.scheme == 'http') return null;
  if (current.host == '127.0.0.1' && current.scheme == 'http') {
    return current.replace(host: 'localhost');
  }
  throw StateError('Local emulator web builds require http://localhost.');
}

/// Host-side loopback is exposed to an Android emulator at 10.0.2.2.
/// Browser debug sessions use explicit IPv4 loopback, matching the backend
/// listeners even when localhost resolves to IPv6 or the browser reports Android.
String firebaseEmulatorHost({
  required bool isWeb,
  required TargetPlatform platform,
}) => isWeb
    ? '127.0.0.1'
    : platform == TargetPlatform.android
    ? '10.0.2.2'
    : 'localhost';
