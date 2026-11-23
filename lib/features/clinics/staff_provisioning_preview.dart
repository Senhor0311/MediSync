import 'package:flutter/material.dart';

/// Synthetic design preview; intentionally has no repository or Auth dependency.
class StaffProvisioningPreview extends StatelessWidget {
  const StaffProvisioningPreview({super.key, required this.clinicName});

  final String clinicName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a practitioner', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'UI preview using fictional staff. Provisioning needs an approved trusted workflow.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showPreview(context, 'Doctor'),
                  icon: const Icon(Icons.medical_services_outlined),
                  label: const Text('Preview doctor'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showPreview(context, 'Specialist'),
                  icon: const Icon(Icons.health_and_safety_outlined),
                  label: const Text('Preview specialist'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showPreview(BuildContext context, String role) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add $role · preview'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Clinic: $clinicName'),
            const SizedBox(height: 8),
            Text('Name: Example $role'),
            Text('Email: ${role.toLowerCase()}@example.test'),
            const SizedBox(height: 16),
            const Text(
              'This is sample UI only. No account, invitation, role, membership or care grant is created.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close preview'),
          ),
        ],
      ),
    );
  }
}
