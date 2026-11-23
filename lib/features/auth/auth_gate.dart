import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../app/app_shell.dart';
import '../settings/theme_controller.dart';
import 'auth_controller.dart';
import 'auth_gateway.dart';
import 'auth_models.dart';
import 'credential_validation.dart';
import 'mfa_panel.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.controller,
    required this.themeController,
    this.invitationId,
    this.onInvitationAccepted,
  });
  final AuthController controller;
  final ThemeController themeController;
  final String? invitationId;
  final VoidCallback? onInvitationAccepted;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.busy) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (controller.mfaChallenge != null) {
        return TotpChallengePanel(controller: controller);
      }
      return switch (controller.access.kind) {
        AccessKind.signedOut => _Credentials(controller: controller),
        AccessKind.unverified => _AccountStep(
          controller: controller,
          title: 'Verify your email',
          message:
              'Open the verification link sent to ${controller.email}. '
              'Then return here and check again. Protected information stays closed until verification.',
          actionLabel: 'I verified my email',
          action: () => controller.refresh(reload: true),
          extraActionLabel: 'Resend verification email',
          extraAction: controller.sendVerification,
          extraContent:
              kDebugMode &&
                  (const bool.fromEnvironment('USE_FIREBASE_EMULATORS') ||
                      const String.fromEnvironment('FIREBASE_ENV') ==
                          'emulator') &&
                  controller.gateway is EmulatorEmailVerifier
              ? _EmulatorVerification(controller: controller)
              : null,
        ),
        AccessKind.profileRequired => _ProfileStep(controller: controller),
        AccessKind.pending => _PendingStep(
          controller: controller,
          invitationId: invitationId,
          onAccepted: onInvitationAccepted,
        ),
        AccessKind.blocked => _AccountStep(
          controller: controller,
          title: 'Access unavailable',
          message: controller.error ?? 'Your account is inactive or access could not be checked. Contact an administrator if this continues.',
          actionLabel: 'Check access again',
          action: () => controller.refresh(reload: true),
        ),
        AccessKind.mfaRequired => Scaffold(
          appBar: AppBar(title: const Text('Staff authentication required')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text(
                  'Staff and administrator operations require a Firebase TOTP sign-in. Enrol an authenticator below, then sign out and sign in to complete the challenge. Staff authentication lasts at most 8 hours; administrator operations require authentication within 15 minutes. Screen activity does not extend these limits. Contact your trusted recovery operator if you have lost every authenticator.',
                ),
                TotpEnrollmentPanel(user: controller.gateway.currentUser!),
                TextButton(
                  onPressed: () => controller.refresh(reload: true),
                  child: const Text('Check authentication again'),
                ),
                TextButton(
                  onPressed: controller.signOut,
                  child: const Text('Sign out and sign in again'),
                ),
              ],
            ),
          ),
        ),
        AccessKind.ready => AppShell(
          themeController: themeController,
          authController: controller,
        ),
      };
    },
  );
}

class _Credentials extends StatefulWidget {
  const _Credentials({required this.controller});
  final AuthController controller;
  @override
  State<_Credentials> createState() => _CredentialsState();
}

class _CredentialsState extends State<_Credentials> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String mode = 'signIn';
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (mode == 'register') {
      await widget.controller.register(_email.text, _password.text);
    } else if (mode == 'reset') {
      final sent = await widget.controller.resetPassword(_email.text);
      if (sent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'If this account exists, Firebase will send reset instructions.',
            ),
          ),
        );
      }
    } else {
      await widget.controller.signIn(_email.text, _password.text);
    }
  }

  @override
  Widget build(BuildContext context) => _Frame(
    title: switch (mode) {
      'register' => 'Create a patient account',
      'reset' => 'Reset password',
      _ => 'Sign in',
    },
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mode == 'register')
            const Text(
              'Public registration creates patient access only. Invited staff create their credentials here, then accept an invitation after verifying email. No staff role is assigned by registration.',
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email address'),
            validator: validateEmail,
          ),
          if (mode != 'reset') ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: true,
              autofillHints: [
                mode == 'register'
                    ? AutofillHints.newPassword
                    : AutofillHints.password,
              ],
              decoration: const InputDecoration(labelText: 'Password'),
              validator: (value) => mode == 'register'
                  ? validateNewPassword(value)
                  : value == null || value.isEmpty
                  ? 'Enter your password.'
                  : null,
            ),
          ],
          const SizedBox(height: 20),
          _Error(controller: widget.controller),
          if (!supportsTotp)
            const Text(
              'Staff accounts with an authenticator must sign in through the supported web or mobile route. This native desktop integration cannot complete TOTP.',
            ),
          FilledButton(
            onPressed: widget.controller.busy ? null : _submit,
            child: Text(
              mode == 'register'
                  ? 'Create account'
                  : mode == 'reset'
                  ? 'Send reset email'
                  : 'Sign in',
            ),
          ),
          TextButton(
            onPressed: () =>
                setState(() => mode = mode == 'signIn' ? 'register' : 'signIn'),
            child: Text(
              mode == 'signIn' ? 'Create an account' : 'Back to sign in',
            ),
          ),
          if (mode == 'signIn')
            TextButton(
              onPressed: () => setState(() => mode = 'reset'),
              child: const Text('Forgot password?'),
            ),
        ],
      ),
    ),
  );
}

class _ProfileStep extends StatefulWidget {
  const _ProfileStep({required this.controller});
  final AuthController controller;
  @override
  State<_ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends State<_ProfileStep> {
  final name = TextEditingController();
  bool acknowledged = false;
  @override
  void initState() {
    super.initState();
    name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Frame(
    title: 'Profile or access review required',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'A new verified account needs a basic profile before protected access can be checked. If you already completed this step, your account may be inactive; contact an administrator if saving is denied.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: name,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        const Text(
          'Privacy notice text is awaiting project approval. This research prototype uses only synthetic data. Acknowledgement of draft version $provisionalNoticeVersion is recorded; it is not an approved production privacy notice.',
        ),
        CheckboxListTile(
          value: acknowledged,
          onChanged: (value) => setState(() => acknowledged = value ?? false),
          title: const Text(
            'I acknowledge this draft notice and will use synthetic data only.',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        _Error(controller: widget.controller),
        FilledButton(
          onPressed: acknowledged && name.text.trim().isNotEmpty
              ? () => widget.controller.createProfile(name.text)
              : null,
          child: const Text('Save profile and acknowledgement'),
        ),
        TextButton(
          onPressed: widget.controller.signOut,
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}

class _PendingStep extends StatefulWidget {
  const _PendingStep({
    required this.controller,
    this.invitationId,
    this.onAccepted,
  });
  final AuthController controller;
  final String? invitationId;
  final VoidCallback? onAccepted;
  @override
  State<_PendingStep> createState() => _PendingStepState();
}

class _PendingStepState extends State<_PendingStep> {
  final invite = TextEditingController();
  @override
  void initState() {
    super.initState();
    invite.text = widget.invitationId ?? '';
  }

  @override
  void didUpdateWidget(_PendingStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.invitationId != widget.invitationId &&
        widget.invitationId != null) {
      invite.text = widget.invitationId!;
    }
  }

  @override
  void dispose() {
    invite.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (await widget.controller.acceptInvitation(invite.text.trim())) {
      widget.onAccepted?.call();
    }
  }

  @override
  Widget build(BuildContext context) => _Frame(
    title: 'No active clinic access',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'No active workspace grant could be resolved. Staff access requires an invitation and an active clinic membership. Check access again or contact an administrator if this continues.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: invite,
          decoration: const InputDecoration(labelText: 'Invitation ID'),
        ),
        const SizedBox(height: 12),
        _Error(controller: widget.controller),
        FilledButton(
          onPressed: _accept,
          child: const Text('Accept invitation'),
        ),
        TextButton(
          onPressed: () => widget.controller.refresh(reload: true),
          child: const Text('Check access again'),
        ),
        TextButton(
          onPressed: widget.controller.signOut,
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}

class _AccountStep extends StatelessWidget {
  const _AccountStep({
    required this.controller,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.action,
    this.extraActionLabel,
    this.extraAction,
    this.extraContent,
  });
  final AuthController controller;
  final String title, message, actionLabel;
  final VoidCallback action;
  final String? extraActionLabel;
  final VoidCallback? extraAction;
  final Widget? extraContent;
  @override
  Widget build(BuildContext context) => _Frame(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message),
        const SizedBox(height: 20),
        _Error(controller: controller),
        FilledButton(onPressed: action, child: Text(actionLabel)),
        if (extraActionLabel != null)
          TextButton(onPressed: extraAction, child: Text(extraActionLabel!)),
        ?extraContent,
        TextButton(
          onPressed: controller.signOut,
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}

class _Error extends StatelessWidget {
  const _Error({required this.controller});
  final AuthController controller;
  @override
  Widget build(BuildContext context) => controller.error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
}

class _EmulatorVerification extends StatefulWidget {
  const _EmulatorVerification({required this.controller});
  final AuthController controller;
  @override
  State<_EmulatorVerification> createState() => _EmulatorVerificationState();
}

class _EmulatorVerificationState extends State<_EmulatorVerification> {
  final link = TextEditingController();
  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 16),
      const Text(
        'Local emulator only: paste the verification link printed in the emulator terminal. This redeems the email-bound action code; it assigns no role.',
      ),
      TextField(
        controller: link,
        decoration: const InputDecoration(
          labelText: 'Local emulator verification link',
        ),
      ),
      TextButton(
        onPressed: () => widget.controller.verifyEmulatorEmailLink(link.text),
        child: const Text('Verify local email link'),
      ),
    ],
  );
}

class _Frame extends StatelessWidget {
  const _Frame({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MediSync')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 20),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
