import 'dart:js_interop';

import 'firebase_emulator_host.dart';

@JS('window.location.replace')
external void _replaceLocation(JSString url);

@JS('window.sessionStorage.removeItem')
external void _removeSessionItem(JSString key);

/// firebase_auth_web 6.3.0 can skip attachment for a named app when an old
/// session marker exists. Force useAuthEmulator to configure the current SDK
/// instance. Remove only this disposable app's emulator marker, never user data.
void prepareEmulatorAuthAttachment() {
  _removeSessionItem('$firebaseEmulatorAppName-firebaseEmulatorOrigin'.toJS);
}

/// firebase_auth_web restores cached emulator attachment only on localhost.
/// Normalize the IPv4 alias before Firebase initialization, preserving routes.
bool redirectEmulatorWebOrigin() {
  final origin = canonicalEmulatorWebOrigin(Uri.base);
  if (origin == null) return false;
  _replaceLocation(origin.toString().toJS);
  return true;
}
