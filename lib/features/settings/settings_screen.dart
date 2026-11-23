import 'package:flutter/material.dart';

import '../../shared/layout/page_content.dart';
import 'theme_controller.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_gateway.dart';
import '../auth/mfa_panel.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.authController,
  });

  final ThemeController controller;
  final AuthController? authController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PageContent(
      storageKey: 'settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Appearance', style: theme.textTheme.headlineLarge),
          ),
          const SizedBox(height: 12),
          Text(
            'Choose how MediSync appears on this device.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: RadioGroup<ThemeMode>(
                groupValue: controller.mode,
                onChanged: (value) {
                  if (value != null && !controller.saving) {
                    controller.setMode(value);
                  }
                },
                child: Column(
                  children: [
                    for (final option in const [
                      (
                        ThemeMode.light,
                        'Light',
                        'Use light surfaces and dark text.',
                        Icons.light_mode_outlined,
                      ),
                      (
                        ThemeMode.dark,
                        'Dark',
                        'Use dark surfaces and light text.',
                        Icons.dark_mode_outlined,
                      ),
                      (
                        ThemeMode.system,
                        'System Default',
                        'Follow your device appearance.',
                        Icons.brightness_auto_outlined,
                      ),
                    ])
                      RadioListTile<ThemeMode>(
                        value: option.$1,
                        enabled: !controller.saving,
                        title: Text(option.$2),
                        subtitle: Text(option.$3),
                        secondary: Icon(option.$4, color: colors.primary),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Semantics(
            liveRegion: true,
            child: Text(
              controller.error ??
                  (controller.saving
                      ? 'Saving appearance…'
                      : 'Your preference is saved on this device. '
                            'System is used until you choose a theme.'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: controller.error == null
                    ? colors.onSurfaceVariant
                    : colors.error,
              ),
            ),
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: controller.saving
                  ? null
                  : () => controller.setMode(controller.mode),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry saving appearance'),
            ),
          ],
          if (authController != null) ...[
            if (authController!.gateway is FirebaseAuthGateway &&
                authController!.gateway.currentUser != null)
              TotpEnrollmentPanel(user: authController!.gateway.currentUser!),
            const SizedBox(height: 32),
            Text('Account', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(authController!.email ?? ''),
            TextButton.icon(
              onPressed: authController!.signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ],
      ),
    );
  }
}
