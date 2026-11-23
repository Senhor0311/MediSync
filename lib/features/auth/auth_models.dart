enum AccessKind {
  signedOut,
  unverified,
  profileRequired,
  pending,
  ready,
  blocked,
  mfaRequired,
}

class ClinicGrant {
  const ClinicGrant(
    this.clinicId,
    this.role,
    this.permissions, {
    this.clinicName,
  });
  final String clinicId;
  final String role;
  final List<String> permissions;
  final String? clinicName;

  bool get canInvite =>
      role == 'clinic_admin' && permissions.contains('staff.invite');
}

class ResolvedAccess {
  const ResolvedAccess(
    this.kind, {
    this.platformAdmin = false,
    this.grants = const [],
  });
  final AccessKind kind;
  final bool platformAdmin;
  final List<ClinicGrant> grants;

  bool get canInvite => platformAdmin || grants.any((grant) => grant.canInvite);
}

const provisionalNoticeVersion = 'draft-stage3-2026-09-24';
