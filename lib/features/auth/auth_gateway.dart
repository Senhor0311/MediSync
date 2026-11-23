import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_emulator_host.dart';

import 'auth_models.dart';

abstract class AuthGateway {
  Stream<User?> get authChanges;
  User? get currentUser;
  Future<void> register(String email, String password);
  Future<void> signIn(String email, String password);
  Future<void> sendVerification();
  Future<void> reloadAndRefreshToken();
  Future<void> resetPassword(String email);
  Future<void> signOut();
  Future<ResolvedAccess> resolveAccess();
  Future<void> createProfile(String displayName);
  Future<void> acceptInvitation(String invitationId);
  Future<String> createInvitation(String clinicId, String email, String role);
}

abstract interface class EmulatorEmailVerifier {
  Future<void> verifyEmulatorEmailLink(String link);
}

abstract interface class AuthenticationAgePolicy {
  bool get authenticationAgeExpired;
}

class FirebaseAuthGateway
    implements AuthGateway, EmulatorEmailVerifier, AuthenticationAgePolicy {
  DateTime? _staffDeadline;
  @override
  bool get authenticationAgeExpired =>
      _staffDeadline != null && !DateTime.now().isBefore(_staffDeadline!);
  FirebaseAuthGateway(this.auth, this.db);
  final FirebaseAuth auth;
  final FirebaseFirestore db;

  @override
  Future<void> verifyEmulatorEmailLink(String link) async {
    if (!kDebugMode ||
        !(const bool.fromEnvironment('USE_FIREBASE_EMULATORS') ||
            const String.fromEnvironment('FIREBASE_ENV') == 'emulator') ||
        auth.app.options.projectId != 'demo-medisync-v3' ||
        auth.currentUser?.email?.endsWith('.test') != true) {
      throw StateError('Local synthetic emulator verification only.');
    }
    final code = emulatorEmailVerificationCode(link);
    final info = await auth.checkActionCode(code);
    if (info.operation != ActionCodeInfoOperation.verifyEmail ||
        info.data['email'] != auth.currentUser!.email) {
      throw StateError('Verification link does not match this account.');
    }
    await auth.applyActionCode(code);
    await reloadAndRefreshToken();
  }

  @override
  Stream<User?> get authChanges => auth.authStateChanges();
  @override
  User? get currentUser => auth.currentUser;

  @override
  Future<void> register(String email, String password) async {
    await auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await sendVerification();
  }

  @override
  Future<void> signIn(String email, String password) async {
    await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> sendVerification() async =>
      auth.currentUser!.sendEmailVerification();

  @override
  Future<void> reloadAndRefreshToken() async {
    await auth.currentUser!.reload();
    await auth.currentUser!.getIdToken(true);
  }

  @override
  Future<void> resetPassword(String email) =>
      auth.sendPasswordResetEmail(email: email.trim());

  @override
  Future<void> signOut() => auth.signOut();

  @override
  Future<ResolvedAccess> resolveAccess() async {
    _staffDeadline = null;
    final user = auth.currentUser!;
    if (!user.emailVerified) {
      return const ResolvedAccess(AccessKind.unverified);
    }
    final token = await user.getIdTokenResult(true);
    try {
      final profile = await db
          .doc('users/${user.uid}')
          .get(const GetOptions(source: Source.server));
      if (!profile.exists) {
        return const ResolvedAccess(AccessKind.profileRequired);
      }
      if (profile.data()?['status'] != 'active') {
        return const ResolvedAccess(AccessKind.blocked);
      }
    } on FirebaseException catch (error) {
      // A permission denial is blocked access, never an invitation to overwrite a profile.
      if (error.code == 'permission-denied') {
        return const ResolvedAccess(AccessKind.blocked);
      }
      rethrow;
    }

    var platformAdmin = false;
    try {
      final marker = await db.doc('platform_admins/${user.uid}').get();
      platformAdmin =
          marker.exists &&
          marker.data()?['uid'] == user.uid &&
          marker.data()?['status'] == 'active';
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
    }

    final grants = <ClinicGrant>[];
    final snapshot = await db
        .collectionGroup('members')
        .where('userId', isEqualTo: user.uid)
        .limit(50)
        .get();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final clinicId = data['clinicId'];
      final role = data['staffRole'];
      final permissions = data['permissions'];
      if (doc.id != user.uid ||
          clinicId is! String ||
          role is! String ||
          data['status'] != 'active' ||
          permissions is! List) {
        continue;
      }
      try {
        final clinic = await db.doc('clinic_directory/$clinicId').get();
        if (!clinic.exists || clinic.data()?['status'] != 'active') continue;
        grants.add(
          ClinicGrant(
            clinicId,
            role,
            permissions.whereType<String>().toList(),
            clinicName: clinic.data()?['displayName'] is String
                ? clinic.data()!['displayName'] as String
                : null,
          ),
        );
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
      }
    }
    // An active, verified profile is the Rules-backed patient grant. Staff
    // memberships and the platform marker add privileges, never replace it.
    if (platformAdmin || grants.isNotEmpty) {
      final claims = token.claims ?? const <String, dynamic>{};
      final firebase = claims['firebase'];
      final authenticated = claims['auth_time'];
      final age = authenticated is num
          ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - authenticated
          : double.infinity;
      final limit = platformAdmin || grants.any((g) => g.role == 'clinic_admin')
          ? 900
          : 28800;
      if (authenticated is int) {
        _staffDeadline = DateTime.fromMillisecondsSinceEpoch(
          (authenticated + limit) * 1000,
        );
      }
      if (firebase is! Map ||
          firebase['sign_in_second_factor'] != 'totp' ||
          age < 0 ||
          age >= limit) {
        return const ResolvedAccess(AccessKind.mfaRequired);
      }
    }
    return ResolvedAccess(
      AccessKind.ready,
      platformAdmin: platformAdmin,
      grants: grants,
    );
  }

  @override
  Future<void> createProfile(String displayName) async {
    final uid = auth.currentUser!.uid;
    await db.doc('users/$uid').set({
      'uid': uid,
      'displayName': displayName.trim(),
      'phone': '',
      'locale': 'en',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'consentAt': FieldValue.serverTimestamp(),
      'noticeVersion': provisionalNoticeVersion,
    });
  }

  @override
  Future<void> acceptInvitation(String invitationId) async {
    final uid = auth.currentUser!.uid;
    final inviteRef = db.doc('invitations/$invitationId');
    final invite = await inviteRef.get();
    final data = invite.data();
    if (data == null ||
        data['status'] != 'pending' ||
        data['email'] != auth.currentUser!.email) {
      throw StateError('Invitation unavailable for this verified email.');
    }
    final clinicId = data['clinicId'];
    final role = data['staffRole'];
    final creator = data['createdBy'];
    if (clinicId is! String ||
        role is! String ||
        creator is! String ||
        !['clinic_admin', 'doctor', 'specialist'].contains(role)) {
      throw StateError('Invitation has an invalid format.');
    }
    final batch = db.batch();
    batch.update(inviteRef, {
      'status': 'accepted',
      'acceptedBy': uid,
      'acceptedAt': FieldValue.serverTimestamp(),
      'revision': FieldValue.increment(1),
    });
    batch.set(db.doc('clinic_memberships/$clinicId/members/$uid'), {
      'clinicId': clinicId,
      'userId': uid,
      'staffRole': role,
      'status': 'active',
      'permissions': role == 'clinic_admin'
          ? ['operational.read', 'audit.read', 'staff.invite']
          : ['operational.read'],
      'approvedBy': creator,
      'createdAt': FieldValue.serverTimestamp(),
      'invitationId': invitationId,
      'revision': 1,
    });
    await batch.commit();
  }

  @override
  Future<String> createInvitation(
    String clinicId,
    String email,
    String role,
  ) async {
    final uid = auth.currentUser!.uid;
    final ref = db.collection('invitations').doc();
    await ref.set({
      'invitationId': ref.id,
      'clinicId': clinicId.trim(),
      'email': email.trim(),
      'staffRole': role,
      'status': 'pending',
      'createdBy': uid,
      'revision': 1,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(days: 6)),
      ),
    });
    // The ID is the out-of-band code; the caller needs it.
    return ref.id;
  }
}
