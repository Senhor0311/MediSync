import 'package:flutter/material.dart';

import '../../shared/layout/app_breakpoints.dart';
import '../../shared/layout/page_content.dart';
import '../auth/auth_controller.dart';
import '../auth/accept_invitation_panel.dart';
import '../auth/invite_panel.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.authController});

  final AuthController? authController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PageContent(
      storageKey: 'home',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Workspace overview',
              style: theme.textTheme.headlineLarge,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Appointments, care coordination and clinical information.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 20, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Interface preview',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Semantics(
                    header: true,
                    child: Text(
                      authController == null
                          ? 'No account connected'
                          : 'Account connected',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    authController == null
                        ? 'Sign-in and clinic access are not available yet. '
                              'No role is assigned and no patient information is loaded.'
                        : 'Signed in as ${authController!.email}. '
                              'Access is resolved from protected records. '
                              'No patient information is loaded on this screen.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (authController != null)
                    TextButton.icon(
                      onPressed: () => authController!.refresh(reload: true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check access again'),
                    ),
                ],
              ),
            ),
          ),
          if (authController != null && authController!.access.canInvite) ...[
            const SizedBox(height: 24),
            InvitePanel(
              controller: authController!,
              scope: authController!.access.platformAdmin
                  ? const InvitationScope.platform()
                  : InvitationScope.clinic(
                      authController!.access.grants
                          .firstWhere((grant) => grant.canInvite)
                          .clinicId,
                    ),
            ),
          ],
          if (authController != null) ...[
            const SizedBox(height: 24),
            AcceptInvitationPanel(controller: authController!),
          ],
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text(
              'Planned workflow areas',
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The following services are planned and are not available in this preview.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          const _WorkflowRow(
            title: 'Appointments and arrivals',
            description: 'Scheduling, check-in and queue progress.',
          ),
          const Divider(height: 1),
          const _WorkflowRow(
            title: 'Referrals and follow-up',
            description: 'Care coordination between clinics and practitioners.',
          ),
          const Divider(height: 1),
          const _WorkflowRow(
            title: 'Clinical records',
            description:
                'Patient information with access limited to authorised users.',
          ),
          const SizedBox(height: 24),
          Text(
            'MediSync V3 · Research prototype',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Informational scope only: no links or disabled clinical actions.
class _WorkflowRow extends StatelessWidget {
  const _WorkflowRow({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Text(title, style: theme.textTheme.titleMedium);
    final detail = Text(
      description,
      style: theme.textTheme.bodyLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < AppBreakpoints.tablet ||
              MediaQuery.textScalerOf(context).scale(16) > 24) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 8), detail],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: heading),
              const SizedBox(width: 24),
              Expanded(flex: 3, child: detail),
            ],
          );
        },
      ),
    );
  }
}
