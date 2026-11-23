import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';
import 'auth_models.dart';
import '../encryption/clinical_crypto.dart';

class AuthController extends ChangeNotifier {
  AuthController(
    this.gateway, {
    this.accessTimeout = const Duration(seconds: 25),
  }) {
    _subscription = gateway.authChanges.listen((_) => refresh());
    if (gateway is AuthenticationAgePolicy) {
      _ageTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final policy = gateway;
        if (access.kind == AccessKind.ready &&
            policy is AuthenticationAgePolicy &&
            (policy as AuthenticationAgePolicy).authenticationAgeExpired) {
          ClinicalCrypto.instance?.lock();
          access = const ResolvedAccess(AccessKind.mfaRequired);
          notifyListeners();
        }
      });
    }
    refresh();
  }

  final AuthGateway gateway;
  final Duration accessTimeout;
  late final StreamSubscription<User?> _subscription;
  Timer? _ageTimer;
  ResolvedAccess access = const ResolvedAccess(AccessKind.signedOut);
  bool busy = true;
  bool invitationBusy = false;
  String? error;
  MultiFactorResolver? mfaChallenge;
  int _revision = 0;

  String? get email => gateway.currentUser?.email;

  Future<void> refresh({bool reload = false}) async {
    final revision = ++_revision;
    busy = true;
    error = null;
    notifyListeners();
    var nextAccess = const ResolvedAccess(AccessKind.signedOut);
    String? nextError;
    try {
      if (gateway.currentUser == null) {
        nextAccess = const ResolvedAccess(AccessKind.signedOut);
      } else {
        if (reload) await gateway.reloadAndRefreshToken();
        final user = gateway.currentUser;
        nextAccess = user == null
            ? const ResolvedAccess(AccessKind.signedOut)
            : !user.emailVerified
            ? const ResolvedAccess(AccessKind.unverified)
            : await gateway.resolveAccess().timeout(accessTimeout);
      }
    } catch (_) {
      nextAccess = const ResolvedAccess(AccessKind.blocked);
      nextError = 'Account access could not be checked. Retry while online.';
    } finally {
      if (revision == _revision) {
        access = nextAccess;
        if (nextAccess.kind != AccessKind.ready) {
          ClinicalCrypto.instance?.lock();
        }
        error = nextError;
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _run(
    Future<void> Function() action, {
    bool refreshAfter = true,
  }) async {
    if (busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
      if (refreshAfter) {
        busy = false;
        await refresh();
      } else {
        busy = false;
        notifyListeners();
      }
      return true;
    } on FirebaseAuthMultiFactorException catch (exception) {
      mfaChallenge = exception.resolver;
      error =
          'Enter a code from an enrolled authenticator to finish signing in.';
    } on FirebaseAuthException catch (exception) {
      if (kDebugMode) {
        debugPrint('Authentication failure code: ${exception.code}');
      }
      error = switch (exception.code) {
        'invalid-email' => 'Enter a valid email address.',
        'weak-password' => 'Choose a stronger password.',
        'email-already-in-use' =>
          'This email already has an account. Sign in instead.',
        'invalid-credential' ||
        'wrong-password' ||
        'user-not-found' => 'Email or password is incorrect.',
        'too-many-requests' => 'Too many attempts. Try again later.',
        'user-disabled' =>
          'This account is disabled. Contact an administrator.',
        _ => 'Authentication failed. Please retry.',
      };
    } catch (exception) {
      error = exception is StateError ? exception.message.toString() : 'Request was denied or could not be completed. Check access and retry.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  Future<bool> register(String email, String password) =>
      _run(() => gateway.register(email, password));
  Future<bool> signIn(String email, String password) =>
      _run(() => gateway.signIn(email, password));
  Future<bool> sendVerification() =>
      _run(gateway.sendVerification, refreshAfter: false);
  Future<bool> verifyEmulatorEmailLink(String link) => _run(() async {
    if (gateway is! EmulatorEmailVerifier) {
      throw StateError('Verification unavailable.');
    }
    await (gateway as EmulatorEmailVerifier).verifyEmulatorEmailLink(link);
  });
  Future<bool> resetPassword(String email) =>
      _run(() => gateway.resetPassword(email), refreshAfter: false);
  Future<bool> signOut() {
    ClinicalCrypto.instance?.lock();
    return _run(gateway.signOut);
  }

  Future<bool> resolveTotp(String enrollmentId, String code) => _run(() async {
    final resolver = mfaChallenge;
    if (resolver == null) throw StateError('Start sign-in again.');
    final assertion = await TotpMultiFactorGenerator.getAssertionForSignIn(
      enrollmentId,
      code.trim(),
    );
    await resolver.resolveSignIn(assertion);
    mfaChallenge = null;
  });
  void cancelMfa() {
    mfaChallenge = null;
    error = null;
    notifyListeners();
  }

  Future<bool> createProfile(String displayName) =>
      _run(() => gateway.createProfile(displayName));
  Future<bool> acceptInvitation(String invitationId) =>
      _run(() => gateway.acceptInvitation(invitationId));

  Future<String?> createInvitation(
    String clinicId,
    String email,
    String role,
  ) async {
    if (busy || invitationBusy || access.kind != AccessKind.ready) return null;
    invitationBusy = true;
    error = null;
    notifyListeners();
    try {
      return await gateway.createInvitation(clinicId, email, role);
    } catch (exception) {
      error = exception is StateError ? exception.message.toString() : 'Invitation was denied or could not be created. Check your access and retry.';
      return null;
    } finally {
      invitationBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    _revision++;
    _subscription.cancel();
    super.dispose();
  }
}
