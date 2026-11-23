import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_emulator_host.dart';

// Android can auto-initialize bundled default configuration. Windows instead
// needs a synthetic default app for the native Firestore delegate factory.
// Initialization and every repository share the same platform selector.
const _useEmulators =
    String.fromEnvironment('FIREBASE_ENV') == 'emulator' ||
    bool.fromEnvironment('USE_FIREBASE_EMULATORS');
FirebaseApp get medisyncFirebaseApp => Firebase.app(
  firebaseInitializationAppName(
        useEmulators: _useEmulators,
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
      ) ??
      '[DEFAULT]',
);
FirebaseAuth get medisyncAuth =>
    FirebaseAuth.instanceFor(app: medisyncFirebaseApp);
FirebaseFirestore get medisyncFirestore =>
    FirebaseFirestore.instanceFor(app: medisyncFirebaseApp);
