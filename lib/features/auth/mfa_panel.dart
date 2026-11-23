import 'inactivity_session.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'auth_controller.dart';
import '../encryption/clinical_crypto.dart';

bool get supportsTotp =>
    kIsWeb ||
    [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

class TotpChallengePanel extends StatefulWidget {
  const TotpChallengePanel({super.key, required this.controller});
  final AuthController controller;
  @override
  State<TotpChallengePanel> createState() => _TotpChallengePanelState();
}

class _TotpChallengePanelState extends State<TotpChallengePanel> {
  final code = TextEditingController();
  String? factor;
  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!supportsTotp) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Use a supported authenticator route'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This native desktop integration cannot complete Firebase TOTP. Open MediSync in a supported web browser or on Android, iOS or macOS. No factor verification has completed here.',
              ),
              TextButton(
                onPressed: widget.controller.cancelMfa,
                child: const Text('Back to sign in'),
              ),
            ],
          ),
        ),
      );
    }
    final factors = widget.controller.mfaChallenge!.hints
        .where((f) => f.factorId == 'totp')
        .toList();
    factor ??= factors.firstOrNull?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Authenticator verification')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Complete Firebase sign-in using an enrolled authenticator. Your encryption recovery code is separate.',
                ),
                if (factors.isEmpty)
                  const Text(
                    'No supported TOTP factor is available. SMS is outside this no-cost build. Contact the trusted account-recovery operator.',
                  ),
                if (factors.isNotEmpty) ...[
                  DropdownButton<String>(
                    isExpanded: true,
                    value: factor,
                    items: [
                      for (final f in factors)
                        DropdownMenuItem(
                          value: f.uid,
                          child: Text(
                            f.displayName ?? 'Authenticator',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => factor = v),
                  ),
                  TextField(
                    onChanged: (_) => InactivitySession.reportActivity(context),
                    controller: code,
                    keyboardType: TextInputType.number,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 8,
                    decoration: const InputDecoration(
                      labelText: 'Authenticator code',
                    ),
                  ),
                  FilledButton(
                    onPressed: widget.controller.busy
                        ? null
                        : () async {
                            if (await widget.controller.resolveTotp(
                              factor!,
                              code.text,
                            )) {
                              code.clear();
                            }
                          },
                    child: const Text('Verify authenticator'),
                  ),
                ],
                if (widget.controller.error != null)
                  Text(widget.controller.error!),
                TextButton(
                  onPressed: widget.controller.cancelMfa,
                  child: const Text('Cancel sign-in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TotpEnrollmentPanel extends StatefulWidget {
  const TotpEnrollmentPanel({super.key, required this.user});
  final User user;
  @override
  State<TotpEnrollmentPanel> createState() => _TotpEnrollmentPanelState();
}

class _TotpEnrollmentPanelState extends State<TotpEnrollmentPanel> {
  List<MultiFactorInfo> factors = [];
  TotpSecret? secret;
  bool busy = false, backedUp = false;
  String? message;
  final code = TextEditingController(),
      label = TextEditingController(text: 'Personal authenticator');
  bool get supported => supportsTotp;
  @override
  void initState() {
    super.initState();
    if (supported) load();
  }

  @override
  void dispose() {
    secret = null;
    code.dispose();
    label.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final result = await widget.user.multiFactor.getEnrolledFactors();
      if (mounted) setState(() => factors = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Firebase factor settings are unavailable on this platform or project.',
        );
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => message =
              e is FirebaseAuthException && e.code == 'user-token-expired'
              ? 'Firebase ended this session after a factor change. Sign in again to check the remaining authenticators.'
              : e is FirebaseAuthException && e.code == 'requires-recent-login'
              ? 'Sign out and sign in again, then retry this sensitive action.'
              : 'Firebase could not complete this action. TOTP requires Identity Platform and an enabled TOTP provider on this Spark project. Check the code, current login and configuration. No factor change is confirmed.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enrol() async {
    if (secret == null ||
        !backedUp ||
        !RegExp(r'^\d{6,8}$').hasMatch(code.text.trim()) ||
        label.text.trim().isEmpty) {
      return;
    }
    await run(() async {
      final assertion =
          await TotpMultiFactorGenerator.getAssertionForEnrollment(
            secret!,
            code.text.trim(),
          );
      await widget.user.multiFactor.enroll(
        assertion,
        displayName: label.text.trim(),
      );
      if (mounted) {
        setState(() {
          secret = null;
          code.clear();
          backedUp = false;
          message = 'Authenticator enrolled by Firebase. Register a second authenticator or keep a protected backup.';
        });
      }
      await load();
    });
  }

  Future<void> remove(MultiFactorInfo factor) async {
    if (factors.length <= 1) {
      setState(
        () => message = 'Add and verify a replacement authenticator before removing the last factor. Lost-factor recovery requires a trusted operator.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove authenticator?'),
        content: const Text(
          'Remove only after verifying a replacement authenticator. Clinical keys use a separate recovery code. Sign in again after changing factors.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove factor'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(() async {
        await widget.user.multiFactor.unenroll(factorUid: factor.uid);
        ClinicalCrypto.instance?.lock();
        await widget.user.getIdToken(true);
        await load();
        if (mounted) {
          setState(() => message = 'Firebase removed the selected factor.');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Authenticator security',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'TOTP is mandatory for staff and administrator operations. Patient ordinary access remains separate. Firebase validates the second factor. SMS is not used. Password reset and the clinical encryption recovery code do not replace a lost authenticator. Keep a protected backup or enrol a second authenticator; otherwise a trusted operator must review account recovery.',
          ),
          if (!supported)
            const Text(
              'Firebase MFA is not supported by this desktop integration. Use Android, iOS, macOS or web. Each target still needs its own configuration and acceptance.',
            ),
          if (supported) ...[
            for (final f in factors)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f.displayName ?? 'Authenticator'),
                subtitle: Text(f.factorId),
                trailing: TextButton(
                  onPressed: busy ? null : () => remove(f),
                  child: const Text('Remove'),
                ),
              ),
            if (secret == null)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final session = await widget.user.multiFactor
                            .getSession();
                        final s = await TotpMultiFactorGenerator.generateSecret(
                          session,
                        );
                        if (mounted) {
                          setState(() {
                            secret = s;
                            backedUp = false;
                          });
                        }
                      }),
                child: const Text('Add authenticator'),
              ),
            if (secret != null) ...[
              const Text(
                'Enter this setup key manually in your authenticator using time-based codes. Save a protected backup before confirming. This secret is shown only during enrolment.',
              ),
              SelectableText(secret!.secretKey),
              TextField(
                onChanged: (_) => InactivitySession.reportActivity(context),
                controller: label,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Authenticator label',
                ),
              ),
              CheckboxListTile(
                value: backedUp,
                onChanged: busy
                    ? null
                    : (v) => setState(() => backedUp = v ?? false),
                title: const Text(
                  'I saved a protected backup and understand account-recovery limits',
                ),
              ),
              TextField(
                onChanged: (_) => InactivitySession.reportActivity(context),
                controller: code,
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: 'Authenticator setup code',
                ),
              ),
              FilledButton(
                onPressed: busy || !backedUp ? null : enrol,
                child: const Text('Confirm authenticator'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        secret = null;
                        code.clear();
                        backedUp = false;
                      }),
                child: const Text('Cancel enrolment'),
              ),
            ],
            TextButton(
              onPressed: busy ? null : load,
              child: const Text('Refresh factors'),
            ),
          ],
          if (busy) const LinearProgressIndicator(),
          if (message != null) Text(message!),
        ],
      ),
    ),
  );
}
