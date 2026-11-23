import '../../features/records/record_choices.dart';

import 'package:flutter/material.dart';

import '../../firebase_clients.dart';

import '../../features/auth/accept_invitation_panel.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/auth/account_admin_panel.dart';
import '../../features/auth/invite_panel.dart';
import '../../features/clinics/clinic_details_panel.dart';
import '../../features/clinics/clinic_repository.dart';
import '../../features/clinics/staff_panel.dart';
import '../../features/records/record_repository.dart';
import '../../features/records/records_panel.dart';
import '../../features/appointments/appointment_repository.dart';
import '../../features/appointments/appointments_panel.dart';
import '../../features/queue/queue_panel.dart';
import '../../features/queue/queue_repository.dart';
import '../../features/notifications/notification_repository.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/referrals/referral_repository.dart';
import '../../features/referrals/referrals_panel.dart';
import '../../features/privacy/privacy_repository.dart';
import '../../features/privacy/privacy_panel.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/home/role_dashboard.dart';
import '../../features/home/dashboard_repository.dart';
import '../../shared/layout/adaptive_scaffold.dart';
import '../../shared/layout/page_content.dart';
import 'route_policy.dart';

class RoleShell extends StatelessWidget {
  const RoleShell({
    super.key,
    required this.view,
    required this.controller,
    required this.themeController,
    required this.navigate,
    this.clinicRepository,
    this.recordRepository,
    this.appointmentRepository,
    this.queueRepository,
    this.referralRepository,
    this.notificationRepository,
    this.privacyRepository,
    this.dashboardRepository,
  });

  final RouteView view;
  final AuthController controller;
  final ThemeController themeController;
  final ValueChanged<String> navigate;
  final ClinicRepository? clinicRepository;
  final RecordRepository? recordRepository;
  final AppointmentRepository? appointmentRepository;
  final QueueRepository? queueRepository;
  final ReferralRepository? referralRepository;
  final NotificationRepository? notificationRepository;
  final PrivacyRepository? privacyRepository;
  final DashboardRepository? dashboardRepository;

  @override
  Widget build(BuildContext context) {
    final role = view.context!;
    final sections = RoutePolicy.sections(role);
    final selected = view.section == 'invitation'
        ? sections.indexOf('invitations')
        : sections.indexOf(view.section);
    final destinations = [
      for (final section in sections) _destination(section),
    ];
    final mobileSections = switch (role.role) {
      'patient' => const ['', 'appointments', 'notifications', 'settings'],
      'doctor' => const ['', 'queue', 'referrals', 'settings'],
      'specialist' => const ['', 'referrals', 'notifications', 'settings'],
      'admin' => const ['', 'team', 'schedule', 'settings'],
      _ => const ['', 'clinics', 'privacy-review', 'settings'],
    };
    final available = RoutePolicy.contexts(controller.access);
    late final repository =
        clinicRepository ??
        FirestoreClinicRepository(medisyncFirestore, medisyncAuth);
    late final records =
        recordRepository ??
        FirestoreRecordRepository(medisyncFirestore, medisyncAuth);
    late final appointments =
        appointmentRepository ??
        FirestoreAppointmentRepository(medisyncFirestore, medisyncAuth);
    late final queues =
        queueRepository ??
        FirestoreQueueRepository(medisyncFirestore, medisyncAuth);
    late final referrals =
        referralRepository ??
        FirestoreReferralRepository(medisyncFirestore, medisyncAuth);
    late final notifications =
        notificationRepository ??
        FirestoreNotificationRepository(medisyncFirestore, medisyncAuth);
    late final privacy =
        privacyRepository ??
        FirestorePrivacyRepository(medisyncFirestore, medisyncAuth);
    String clinicName(String? id) {
      if (id == null) return 'Clinic';
      for (final grant in controller.access.grants) {
        if (grant.clinicId == id && grant.clinicName != null) {
          return grant.clinicName!;
        }
      }
      return 'Clinic';
    }

    late final recordChoices = RecordChoiceSource(
      medisyncFirestore,
      medisyncAuth,
      role.role,
      role.clinicId ?? '',
      clinicName(role.clinicId),
    );
    return AdaptiveScaffold(
      title: '${role.title} dashboard',
      destinations: destinations,
      mobileDestinationIndices: [
        for (final section in mobileSections) sections.indexOf(section),
      ],
      selectedIndex: selected < 0 ? 0 : selected,
      onDestinationSelected: (index) => navigate(
        sections[index].isEmpty ? role.base : '${role.base}/${sections[index]}',
      ),
      actions: [
        PopupMenuButton<String>(
          tooltip: 'More destinations',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (section) =>
              navigate(section.isEmpty ? role.base : '${role.base}/$section'),
          itemBuilder: (context) => [
            for (final section in sections.where(
              (item) => !mobileSections.contains(item),
            ))
              PopupMenuItem(value: section, child: Text(_label(section))),
          ],
        ),
        if (available.length > 1)
          PopupMenuButton<String>(
            tooltip: 'Switch workspace',
            icon: const Icon(Icons.switch_account_outlined),
            onSelected: navigate,
            itemBuilder: (context) => [
              for (final option in available)
                PopupMenuItem(
                  value: option.base,
                  child: Text(
                    option.clinicId == null
                        ? option.title
                        : '${option.title} · ${clinicName(option.clinicId)}',
                  ),
                ),
            ],
          ),
      ],
      body: view.section == 'settings'
          ? SettingsScreen(
              controller: themeController,
              authController: controller,
            )
          : view.section.isEmpty
          ? RoleDashboard(
              role: role,
              clinicName: clinicName(role.clinicId),
              displayName: controller.email,
              denied: view.denied,
              repository: dashboardRepository,
              uid: controller.gateway.currentUser?.uid ?? '',
              onOpenSection: (section) => navigate('${role.base}/$section'),
            )
          : PageContent(
              storageKey: '${role.base}/${view.section}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (view.denied) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'That destination is unavailable for your current access. Showing your dashboard instead.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (view.section == 'clinics' && role.role == 'platform') ...[
                    ClinicDetailsPanel(repository: repository),
                  ] else if (view.section == 'accounts' &&
                      role.role == 'platform') ...[
                    AccountAdminPanel(
                      service: AccountAdministration(
                        medisyncFirestore,
                        medisyncAuth,
                      ),
                    ),
                  ] else if (view.section == 'privacy') ...[
                    PrivacyPanel(key: ValueKey(role.base), repository: privacy),
                  ] else if (view.section == 'privacy-review' &&
                      role.role == 'platform') ...[
                    PrivacyPanel(repository: privacy, review: true),
                  ] else if (view.section == 'notifications' &&
                      (role.role == 'patient' ||
                          role.role == 'doctor' ||
                          role.role == 'specialist')) ...[
                    NotificationsPanel(
                      key: ValueKey(role.base),
                      repository: notifications,
                      role: role.role,
                      clinicId: role.clinicId,
                      onOpenSection: (section) =>
                          navigate('${role.base}/$section'),
                    ),
                  ] else if (view.section == 'appointments' &&
                      role.role == 'patient') ...[
                    AppointmentsPanel(repository: appointments),
                  ] else if (view.section == 'referrals' &&
                      (role.role == 'patient' ||
                          role.role == 'doctor' ||
                          role.role == 'specialist')) ...[
                    ReferralsPanel(
                      key: ValueKey(role.base),
                      repository: referrals,
                      role: role.role,
                      clinicId: role.clinicId,
                      clinicName: clinicName(role.clinicId),
                    ),
                  ] else if (view.section == 'queue' &&
                      role.role == 'patient') ...[
                    PatientQueuePanel(repository: queues),
                  ] else if (view.section == 'queue' &&
                      role.role == 'doctor') ...[
                    PractitionerQueuePanel(
                      repository: queues,
                      clinicId: role.clinicId!,
                      providerId: controller.gateway.currentUser?.uid ?? '',
                      clinicName: clinicName(role.clinicId),
                    ),
                  ] else if (view.section == 'schedule' &&
                      role.role == 'doctor') ...[
                    if (appointments is AppointmentCommands) ...[
                      AppointmentsPanel(
                        repository: appointments,
                        assistedClinicId: role.clinicId!,
                        assistedProviderId: controller.gateway.currentUser?.uid,
                      ),
                      const SizedBox(height: 24),
                    ],
                    StaffSchedulePanel(
                      repository: appointments,
                      clinicId: role.clinicId!,
                      providerId: controller.gateway.currentUser?.uid ?? '',
                      clinicName: clinicName(role.clinicId),
                    ),
                  ] else if (view.section == 'schedule' &&
                      role.role == 'admin') ...[
                    if (appointments is AppointmentCommands) ...[
                      AppointmentsPanel(
                        repository: appointments,
                        assistedClinicId: role.clinicId!,
                      ),
                      const SizedBox(height: 24),
                    ],
                    ClinicSchedulePanel(
                      repository: appointments,
                      clinicId: role.clinicId!,
                      clinicName: clinicName(role.clinicId),
                    ),
                  ] else if (view.section == 'records' &&
                      (role.role == 'patient' ||
                          role.role == 'doctor' ||
                          role.role == 'specialist')) ...[
                    RecordsPanel(
                      key: ValueKey(role.base),
                      repository: records,
                      patientMode: role.role == 'patient',
                      patientId: controller.gateway.currentUser?.uid ?? '',
                      clinicId: role.clinicId,
                      clinicLabel: clinicName(role.clinicId),
                      loadPatientChoices: role.role == 'patient'
                          ? null
                          : recordChoices.load,
                      loadMorePatientChoices: role.role == 'patient'
                          ? null
                          : () => recordChoices.load(more: true),
                      hasMorePatientChoices: () => recordChoices.hasMore,
                    ),
                  ] else if (view.section == 'details' &&
                      role.role == 'admin') ...[
                    ClinicDetailsPanel(
                      key: ValueKey(role.clinicId),
                      repository: repository,
                      fixedClinicId: role.clinicId,
                      fixedClinicName: clinicName(role.clinicId),
                    ),
                  ] else if (view.section == 'team' &&
                      role.role == 'admin') ...[
                    StaffPanel(
                      key: ValueKey(role.clinicId),
                      repository: repository,
                      clinicId: role.clinicId!,
                      clinicName: clinicName(role.clinicId),
                    ),
                    const SizedBox(height: 16),
                    if (_mayInvite(role, controller))
                      InvitePanel(
                        key: ValueKey('invite:${role.base}'),
                        controller: controller,
                        scope: InvitationScope.clinic(
                          role.clinicId,
                          clinicName: clinicName(role.clinicId),
                        ),
                      ),
                  ] else if (view.section == 'invitation' ||
                      view.section == 'invitations') ...[
                    Text(
                      'Invitations',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 12),
                    AcceptInvitationPanel(
                      key: ValueKey(view.invitationId),
                      controller: controller,
                      initialInvitationId: view.invitationId,
                      onAccepted: () => navigate(
                        RoutePolicy.contexts(controller.access).first.base,
                      ),
                    ),
                    if (view.section == 'invitations' &&
                        _mayInvite(role, controller)) ...[
                      const SizedBox(height: 16),
                      InvitePanel(
                        key: ValueKey('invite:${role.base}'),
                        controller: controller,
                        clinicRepository: repository,
                        scope: role.role == 'platform'
                            ? const InvitationScope.platform()
                            : InvitationScope.clinic(
                                role.clinicId,
                                clinicName: clinicName(role.clinicId),
                              ),
                      ),
                    ],
                  ] else ...[
                    Text(
                      _label(view.section),
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 20),
                    _Placeholder(
                      'Destination unavailable',
                      'Use the navigation menu to open an available workflow.',
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  bool _mayInvite(RoleContext role, AuthController controller) =>
      role.role == 'platform' && controller.access.platformAdmin ||
      role.role == 'admin' &&
          controller.access.grants.any(
            (grant) => grant.clinicId == role.clinicId && grant.canInvite,
          );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.title, this.message);
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message),
        ],
      ),
    ),
  );
}

String _label(String section) => switch (section) {
  '' => 'Overview',
  'details' => 'Clinic details',
  'appointments' => 'Appointments',
  'records' => 'Records',
  'schedule' => 'Schedule',
  'queue' => 'Queue',
  'referrals' => 'Referrals',
  'notifications' => 'Notifications',
  'privacy' => 'Privacy requests',
  'privacy-review' => 'Request review',
  'team' => 'Team',
  'clinics' => 'Clinics',
  'accounts' => 'Accounts',
  'invitations' => 'Invitations',
  _ => 'Settings',
};

AppDestination _destination(String section) {
  final icon = switch (section) {
    '' => Icons.dashboard_outlined,
    'settings' => Icons.tune_outlined,
    'details' => Icons.info_outline,
    'invitations' => Icons.mail_outline,
    'appointments' || 'schedule' => Icons.calendar_today_outlined,
    'records' => Icons.folder_outlined,
    'queue' => Icons.people_outline,
    'referrals' => Icons.send_outlined,
    'notifications' => Icons.notifications_outlined,
    'privacy' => Icons.privacy_tip_outlined,
    'privacy-review' => Icons.fact_check_outlined,
    'team' => Icons.groups_outlined,
    'clinics' => Icons.business_outlined,
    'accounts' => Icons.manage_accounts_outlined,
    _ => Icons.circle_outlined,
  };
  return AppDestination(_label(section), icon, icon);
}
