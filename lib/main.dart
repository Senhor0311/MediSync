import 'features/home/clinic_operations_repository.dart';
import 'features/home/platform_metrics_repository.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/medisync_app.dart';
import 'app/security/app_attestation.dart';
import 'features/home/dashboard_repository.dart';
import 'features/appointments/appointment_repository.dart';
import 'features/clinics/clinic_repository.dart';
import 'features/privacy/privacy_repository.dart';
import 'features/queue/queue_repository.dart';
import 'features/referrals/referral_repository.dart';
import 'features/settings/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/auth_gateway.dart';
import 'firebase_options.dart';
import 'features/encryption/clinical_crypto.dart';
import 'features/notifications/foreground_reminders.dart';
import 'firebase_clients.dart';
import 'firebase_emulator_host.dart';
import 'firebase_emulator_web_origin_stub.dart'
    if (dart.library.js_interop) 'firebase_emulator_web_origin.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const environment = String.fromEnvironment('FIREBASE_ENV');
  const useEmulators =
      environment == 'emulator' ||
      bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  if ((!useEmulators && environment != 'live') ||
      (environment.isNotEmpty && !['live', 'emulator'].contains(environment)) ||
      (useEmulators && environment == 'live')) {
    throw StateError(
      'Select exactly one explicit Firebase environment: FIREBASE_ENV=emulator or FIREBASE_ENV=live.',
    );
  }
  if (useEmulators && !kDebugMode) {
    throw StateError('Firebase emulators require a debug build.');
  }
  if (useEmulators && kIsWeb && redirectEmulatorWebOrigin()) return;
  final configured = DefaultFirebaseOptions.currentPlatform;
  if (!useEmulators &&
      (configured.projectId != 'medisync-v3' ||
          configured.messagingSenderId != '1017272716947')) {
    throw StateError(
      'Live project identity does not match the verified Spark project.',
    );
  }
  final app = await Firebase.initializeApp(
    name: firebaseInitializationAppName(
      useEmulators: useEmulators,
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    ),
    options: useEmulators
        ? FirebaseOptions(
            apiKey: 'fake-api-key',
            appId: configured.appId,
            messagingSenderId: configured.messagingSenderId,
            projectId: 'demo-medisync-v3',
            authDomain: 'demo-medisync-v3.firebaseapp.com',
          )
        : configured,
  );
  await prepareAppAttestation(emulator: useEmulators, app: app);
  // Clinical documents must not be persisted in the SDK's disk cache.
  medisyncFirestore.settings = const Settings(
    persistenceEnabled: false,
    // Some local browser/proxy paths buffer emulator WebChannel streams.
    webExperimentalForceLongPolling: kIsWeb && useEmulators ? true : null,
    webExperimentalAutoDetectLongPolling: kIsWeb && useEmulators ? false : null,
  );
  if (useEmulators) {
    prepareEmulatorAuthAttachment();
    final host = firebaseEmulatorHost(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    );
    await medisyncAuth.useAuthEmulator(host, 9099);
    medisyncFirestore.useFirestoreEmulator(host, 8080);
  }
  ClinicalCrypto.instance = ClinicalCrypto(medisyncFirestore, medisyncAuth);
  final themeController = ThemeController(LocalThemePreferenceStore());
  await themeController.load();
  final authController = AuthController(
    FirebaseAuthGateway(medisyncAuth, medisyncFirestore),
  );
  ForegroundReminders(medisyncFirestore, medisyncAuth, authController);
  runApp(
    MediSyncApp(
      themeController: themeController,
      authController: authController,
      emulatorMode: useEmulators,
      dashboardRepository: ScopedDashboardRepository(
        FirestoreAppointmentRepository(medisyncFirestore, medisyncAuth),
        FirestoreQueueRepository(medisyncFirestore, medisyncAuth),
        FirestoreReferralRepository(medisyncFirestore, medisyncAuth),
        FirestoreClinicRepository(medisyncFirestore, medisyncAuth),
        FirestorePrivacyRepository(medisyncFirestore, medisyncAuth),
        operations: FirestoreClinicOperationsRepository(medisyncFirestore),
        platformMetrics: FirestorePlatformMetricsRepository(medisyncFirestore),
      ),
    ),
  );
}
