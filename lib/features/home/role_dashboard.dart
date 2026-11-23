import 'package:flutter/material.dart';

import '../../app/routing/route_policy.dart';
import '../../app/theme/app_theme.dart';
import '../../shared/layout/page_content.dart';
import 'dashboard_summary.dart';
import 'dashboard_repository.dart';

/// A visual overview only. Every destination performs its own authorized read.
class RoleDashboard extends StatelessWidget {
  const RoleDashboard({
    super.key,
    required this.role,
    required this.clinicName,
    required this.onOpenSection,
    this.displayName,
    this.denied = false,
    this.repository,
    this.uid = '',
  });

  final RoleContext role;
  final String clinicName;
  final String? displayName;
  final ValueChanged<String> onOpenSection;
  final bool denied;
  final DashboardRepository? repository;
  final String uid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isPatient = role.role == 'patient';
    final isPlatform = role.role == 'platform';
    final name = displayName?.split('@').first.trim();
    final heading = switch (role.role) {
      'platform' => 'System Admin',
      'admin' => 'Clinic Admin',
      'doctor' => 'Doctor',
      'specialist' => 'Specialist',
      _ => 'Patient',
    };
    final now = DateTime.now();
    final date =
        '${_weekdays[now.weekday - 1]}, ${_months[now.month - 1]} ${now.day}';

    final actions = switch (role.role) {
      'patient' => const [
        _Action(
          'Check in',
          'queue',
          Icons.medical_services_rounded,
          AppAccent.blue,
        ),
        _Action(
          'Appointments',
          'appointments',
          Icons.calendar_month_rounded,
          AppAccent.purple,
        ),
        _Action(
          'Referrals',
          'referrals',
          Icons.description_rounded,
          AppAccent.red,
        ),
      ],
      'doctor' => const [
        _Action(
          'Current queue',
          'queue',
          Icons.hourglass_top_rounded,
          AppAccent.amber,
        ),
        _Action(
          'Schedule',
          'schedule',
          Icons.calendar_month_rounded,
          AppAccent.purple,
        ),
        _Action('Referrals', 'referrals', Icons.send_rounded, AppAccent.green),
      ],
      'specialist' => const [
        _Action('Referrals', 'referrals', Icons.send_rounded, AppAccent.purple),
        _Action(
          'Follow-up records',
          'records',
          Icons.description_rounded,
          AppAccent.blue,
        ),
        _Action(
          'Notifications',
          'notifications',
          Icons.notifications_rounded,
          AppAccent.green,
        ),
      ],
      'admin' => const [
        _Action('Clinic team', 'team', Icons.groups_rounded, AppAccent.blue),
        _Action(
          'Clinic details',
          'details',
          Icons.business_rounded,
          AppAccent.purple,
        ),
        _Action(
          'Schedule',
          'schedule',
          Icons.calendar_month_rounded,
          AppAccent.green,
        ),
      ],
      _ => const [
        _Action('Clinics', 'clinics', Icons.business_rounded, AppAccent.blue),
        _Action(
          'Accounts',
          'accounts',
          Icons.manage_accounts_rounded,
          AppAccent.green,
        ),
        _Action(
          'Privacy review',
          'privacy-review',
          Icons.fact_check_rounded,
          AppAccent.purple,
        ),
        _Action(
          'Invitations',
          'invitations',
          Icons.mail_rounded,
          AppAccent.green,
        ),
      ],
    };

    return PageContent(
      storageKey: '${role.base}/dashboard',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPlatform ? 'System administration' : 'Welcome back,',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onPrimary.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isPlatform
                      ? 'MediSync'
                      : (name?.isNotEmpty == true ? name! : heading),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colors.onPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 16,
                      color: colors.onPrimary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        date,
                        softWrap: true,
                        style: TextStyle(color: colors.onPrimary),
                      ),
                    ),
                  ],
                ),
                if (!isPatient && !isPlatform) ...[
                  const SizedBox(height: 8),
                  Text(clinicName, style: TextStyle(color: colors.onPrimary)),
                ],
              ],
            ),
          ),
          if (denied) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'That destination is unavailable for your current access. Showing your dashboard instead.',
                  style: TextStyle(color: colors.error),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          if (repository != null && !isPatient) ...[
            DashboardSummary(
              key: ValueKey(role.base),
              repository: repository!,
              role: role.role,
              clinicId: role.clinicId,
              uid: uid,
              onOpenSection: onOpenSection,
            ),
            const SizedBox(height: 24),
          ],
          Text(
            isPlatform ? 'System overview' : 'Quick Actions',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final count = width >= 760 ? 3 : 2;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final action in actions)
                    SizedBox(
                      width: (width - 16 * (count - 1)) / count,
                      child: _ActionCard(
                        action: action,
                        onTap: () => onOpenSection(action.section),
                      ),
                    ),
                ],
              );
            },
          ),
          if (isPatient ||
              role.role == 'doctor' ||
              role.role == 'specialist') ...[
            const SizedBox(height: 28),
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onOpenSection('records'),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      _IconBox(Icons.folder_shared_rounded, colors.primary),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Medical Records',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Open records available to your account',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          if (isPatient ||
              isPlatform ||
              role.role == 'admin' ||
              repository == null)
            Text(
              isPatient
                  ? 'Upcoming Appointments'
                  : role.role == 'doctor'
                  ? 'Current Queue'
                  : isPlatform
                  ? 'Administration'
                  : 'Workspace',
              style: theme.textTheme.titleLarge,
            ),
          const SizedBox(height: 12),
          if (repository != null && isPatient)
            DashboardSummary(
              key: ValueKey(role.base),
              repository: repository!,
              role: role.role,
              clinicId: role.clinicId,
              uid: uid,
              onOpenSection: onOpenSection,
            ),
          if (repository == null || isPlatform || role.role == 'admin')
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(
                      isPlatform
                          ? Icons.admin_panel_settings_outlined
                          : Icons.info_outline,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isPatient
                            ? 'Open Appointments for your current schedule.'
                            : role.role == 'doctor'
                            ? 'Open Current queue for live, authorized queue actions.'
                            : isPlatform
                            ? 'Manage clinics and privacy requests. Clinical records are not available to system administrators.'
                            : role.role == 'admin'
                            ? 'Team and clinic settings are limited to this clinic.'
                            : 'Open referrals for current information. Specialist scheduling is unavailable.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

class _Action {
  const _Action(this.label, this.section, this.icon, this.color);
  final String label;
  final String section;
  final IconData icon;
  final AppAccent color;
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action, required this.onTap});
  final _Action action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 126),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _IconBox(
                  action.icon,
                  AppTheme.actionColor(
                    action.color,
                    Theme.of(context).brightness,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  action.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox(this.icon, this.color);
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, color: color, size: 26),
  );
}
