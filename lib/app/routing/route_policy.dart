import '../../features/auth/auth_models.dart';

/// Presentation routing only. Firestore Rules decide whether data is readable.
class RoleContext {
  const RoleContext(this.role, [this.clinicId]);
  final String role;
  final String? clinicId;

  String get base => clinicId == null
      ? '/$role'
      : '/clinics/${Uri.encodeComponent(clinicId!)}/$role';

  String get title => switch (role) {
    'platform' => 'Platform admin',
    'admin' => 'Clinic admin',
    'doctor' => 'Doctor',
    'specialist' => 'Specialist',
    _ => 'Patient',
  };
}

class RouteView {
  const RouteView(
    this.kind, {
    this.context,
    this.section = '',
    this.denied = false,
    this.invitationId,
  });
  final AccessKind kind;
  final RoleContext? context;
  final String section;
  final bool denied;
  final String? invitationId;
}

class RoutePolicy {
  static List<RoleContext> contexts(ResolvedAccess access) {
    if (access.kind != AccessKind.ready) return const [];
    final grants = [...access.grants]
      ..sort((a, b) {
        final byClinic = a.clinicId.compareTo(b.clinicId);
        return byClinic == 0 ? a.role.compareTo(b.role) : byClinic;
      });
    return [
      if (access.platformAdmin) const RoleContext('platform'),
      for (final role in const ['clinic_admin', 'doctor', 'specialist'])
        for (final grant in grants)
          if (grant.role == role && grant.clinicId.isNotEmpty)
            RoleContext(
              role == 'clinic_admin' ? 'admin' : role,
              grant.clinicId,
            ),
      const RoleContext('patient'),
    ];
  }

  static List<String> sections(RoleContext context) => switch (context.role) {
    'platform' => const [
      '',
      'clinics',
      'accounts',
      'invitations',
      'privacy',
      'privacy-review',
      'settings',
    ],
    'admin' => const [
      '',
      'details',
      'team',
      'schedule',
      'invitations',
      'privacy',
      'settings',
    ],
    'doctor' => const [
      '',
      'schedule',
      'queue',
      'referrals',
      'records',
      'notifications',
      'invitations',
      'privacy',
      'settings',
    ],
    'specialist' => const [
      '',
      'referrals',
      'records',
      'notifications',
      'invitations',
      'privacy',
      'settings',
    ],
    _ => const [
      '',
      'appointments',
      'queue',
      'referrals',
      'records',
      'notifications',
      'invitations',
      'privacy',
      'settings',
    ],
  };

  static RouteView resolve(String requestedPath, ResolvedAccess access) {
    final path = Uri.tryParse(requestedPath)?.path ?? '/';
    final invitation = RegExp(r'^/invitation/([^/]+)$').firstMatch(path);
    final invitationId = invitation?.group(1);
    if (access.kind != AccessKind.ready) {
      return RouteView(access.kind, invitationId: invitationId);
    }
    final available = contexts(access);
    final fallback = available.first;
    if (invitationId != null || path == '/invitation') {
      return RouteView(
        AccessKind.ready,
        context: fallback,
        section: 'invitation',
        invitationId: invitationId,
      );
    }
    for (final context in available) {
      final base = context.base;
      if (path == base) return RouteView(AccessKind.ready, context: context);
      for (final section in sections(context).skip(1)) {
        if (path == '$base/$section') {
          return RouteView(
            AccessKind.ready,
            context: context,
            section: section,
          );
        }
      }
    }
    return RouteView(
      AccessKind.ready,
      context: fallback,
      denied: path != '/' && path != '/sign-in',
    );
  }
}
