import '../auth/inactivity_session.dart';

import 'package:flutter/material.dart';

import 'clinical_crypto.dart';

class VaultGate extends StatefulWidget {
  const VaultGate({
    super.key,
    required this.crypto,
    required this.child,
    required this.signOut,
  });
  final ClinicalCrypto crypto;
  final Widget child;
  final Future<void> Function() signOut;
  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> {
  final code = TextEditingController(), confirmation = TextEditingController();
  bool? enrolled;
  bool busy = false, backedUp = false;
  String? generated, error;
  @override
  void initState() {
    super.initState();
    widget.crypto.addListener(changed);
    load();
  }

  void changed() {
    if (!widget.crypto.unlocked) {
      code.clear();
      confirmation.clear();
      generated = null;
      backedUp = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    try {
      final value = await widget.crypto.enrolled();
      if (mounted) {
        setState(() {
          enrolled = value;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Encryption setup could not be checked. Reconnect and retry.',
        );
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      if (mounted) {
        code.clear();
        confirmation.clear();
        generated = null;
        backedUp = false;
        enrolled = true;
      }
    } catch (e) {
      if (mounted) {
        error = e is ClinicalCryptoFailure
            ? e.message
            : e is StateError
            ? e.message.toString()
            : 'Could not unlock or save the vault. Check your backed-up clinical recovery code, connection and recent sign-in. Password reset and MFA recovery do not recover clinical keys.';
      }
      if (enrolled == false) {
        try {
          if (await widget.crypto.enrolled()) {
            enrolled = true;
            error = 'The vault exists. Unlock it with the code you backed up before setup. Do not generate a replacement identity.';
          }
        } catch (_) {
          /* Keep the backed-up code and retry after reconnecting. */
        }
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> replaceCode() async {
    final replacement = ClinicalCrypto.newCode();
    var entry = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace recovery code'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Save this new code in a protected backup. The old code will stop unlocking the online vault. Previously unlocked devices and copied keys cannot be revoked remotely.',
              ),
              SelectableText(replacement),
              TextField(
                onChanged: (value) {
                  InactivitySession.reportActivity(context);
                  entry = value;
                },
                decoration: const InputDecoration(
                  labelText: 'Re-enter the new code from your backup',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (entry.trim() == replacement) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('I backed it up'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await run(() => widget.crypto.rotate(replacementCode: replacement));
    }
  }

  @override
  void dispose() {
    widget.crypto.removeListener(changed);
    code.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.crypto.unlocked) {
      return Column(
        children: [
          Material(
            child: SafeArea(
              bottom: false,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('Clinical encryption unlocked'),
                  ),
                  TextButton(
                    onPressed: busy ? null : widget.crypto.lock,
                    child: const Text('Lock'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() => widget.crypto.rotate()),
                    child: const Text('Rotate key'),
                  ),
                  TextButton(
                    onPressed: busy ? null : replaceCode,
                    child: const Text('Replace recovery code'),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(),
                    ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          Expanded(child: widget.child),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clinical encryption'),
        actions: [
          TextButton(
            onPressed: busy ? null : widget.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  enrolled == false
                      ? 'Protect your clinical information'
                      : 'Unlock your encrypted vault',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your recovery code is separate from your sign-in password. Keep it in a protected backup. Password reset and administrators cannot recover it. Losing the code and all unlocked sessions makes encrypted information irrecoverable. Sign-out locks this device; every new device needs the code.',
                ),
                if (enrolled == null) ...[
                  if (error == null) const LinearProgressIndicator(),
                  TextButton(
                    onPressed: load,
                    child: const Text('Retry encryption check'),
                  ),
                ],
                if (enrolled == false) ...[
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            generated = ClinicalCrypto.newCode();
                            confirmation.clear();
                            backedUp = false;
                          }),
                    child: const Text('Generate recovery code'),
                  ),
                  if (generated != null) ...[
                    SelectableText(generated!),
                    const Text(
                      'Copy this code now. It is not saved on this device.',
                    ),
                    CheckboxListTile(
                      value: backedUp,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => backedUp = v ?? false),
                      title: const Text(
                        'I saved a protected backup and understand the loss risk',
                      ),
                    ),
                    TextField(
                      controller: confirmation,
                      onChanged: (_) {
                        InactivitySession.reportActivity(context);
                        setState(() {});
                      },
                      decoration: const InputDecoration(
                        labelText: 'Re-enter the code from your backup',
                      ),
                    ),
                    FilledButton(
                      onPressed:
                          busy ||
                              !backedUp ||
                              confirmation.text.trim() != generated
                          ? null
                          : () => run(() => widget.crypto.enrol(generated!)),
                      child: const Text('Create encrypted vault'),
                    ),
                  ],
                ],
                if (enrolled == true) ...[
                  TextField(
                    onChanged: (_) => InactivitySession.reportActivity(context),
                    controller: code,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Recovery code',
                    ),
                    onSubmitted: (_) {
                      if (!busy) run(() => widget.crypto.unlock(code.text));
                    },
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => run(() => widget.crypto.unlock(code.text)),
                    child: const Text('Unlock'),
                  ),
                ],
                if (busy) const LinearProgressIndicator(),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
