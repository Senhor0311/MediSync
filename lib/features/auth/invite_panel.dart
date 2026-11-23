import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../firebase_clients.dart';

import '../clinics/clinic_repository.dart';

import 'auth_controller.dart';
import 'auth_models.dart';

/// UI scope only. Firestore Rules validate every invitation write again.
class InvitationScope {
  const InvitationScope.platform() : clinicId = null, clinicName = null;
  const InvitationScope.clinic(this.clinicId, {this.clinicName});

  final String? clinicId;
  final String? clinicName;
  bool get isPlatform => clinicId == null;

  bool permits(ResolvedAccess access) =>
      access.kind == AccessKind.ready &&
      (isPlatform
          ? access.platformAdmin
          : access.grants.any(
              (grant) => grant.clinicId == clinicId && grant.canInvite,
            ));
}

class InvitePanel extends StatefulWidget {
  const InvitePanel({
    super.key,
    required this.controller,
    required this.scope,
    this.clinicRepository,
  });

  final AuthController controller;
  final InvitationScope scope;
  final ClinicRepository? clinicRepository;

  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  final email = TextEditingController();
  String role = 'doctor';
  String? issuedId;
  String? selectedClinicId;
  Future<List<ClinicDirectoryEntry>>? directory;

  @override
  void initState() {
    super.initState();
    _loadDirectory();
  }

  ClinicRepository get _repository =>
      widget.clinicRepository ??
      FirestoreClinicRepository(medisyncFirestore, medisyncAuth);

  void _loadDirectory() {
    if (widget.scope.isPlatform) directory = _repository.listDirectory();
  }

  @override
  void didUpdateWidget(InvitePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope.clinicId != widget.scope.clinicId) {
      email.clear();
      issuedId = null;
      role = 'doctor';
      selectedClinicId = null;
      _loadDirectory();
    }
  }

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!widget.scope.permits(widget.controller.access)) return;
    final clinicId = widget.scope.clinicId ?? selectedClinicId;
    final recipient = email.text.trim();
    if (clinicId == null ||
        !RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(clinicId) ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(recipient) ||
        (const String.fromEnvironment('FIREBASE_ENV') != 'live' &&
            !recipient.endsWith('.test')) ||
        recipient == widget.controller.email) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choose an active clinic and enter another fictional .test email address.',
          ),
        ),
      );
      return;
    }
    final id = await widget.controller.createInvitation(
      clinicId,
      recipient,
      widget.scope.isPlatform ? 'clinic_admin' : role,
    );
    if (mounted) setState(() => issuedId = id);
  }

  @override
  Widget build(BuildContext context) {
    final authorised = widget.scope.permits(widget.controller.access);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.scope.isPlatform
                  ? 'Invite clinic admin'
                  : 'Invite doctor or specialist',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              widget.scope.isPlatform
                  ? 'Choose an active clinic by name.'
                  : 'Invitations from this workspace are restricted to ${widget.scope.clinicName ?? 'this clinic'}.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Synthetic prototype only. The recipient creates and verifies their own Auth account. Share the invitation ID separately; it expires after six days. Acceptance creates membership only, not provider publication or clinical access.',
            ),
            if (!authorised) ...[
              const SizedBox(height: 16),
              const Text(
                'Invitation access is no longer active. Refresh access or contact an administrator.',
              ),
            ] else ...[
              const SizedBox(height: 16),
              if (widget.scope.isPlatform)
                FutureBuilder<List<ClinicDirectoryEntry>>(
                  future: directory,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Text(
                        snapshot.hasError
                            ? 'Clinic directory unavailable.'
                            : 'Loading clinics…',
                      );
                    }
                    return DropdownButtonFormField<String>(
                      initialValue: selectedClinicId,
                      decoration: const InputDecoration(
                        labelText: 'Active clinic',
                      ),
                      items: [
                        for (final entry in snapshot.data!)
                          DropdownMenuItem(
                            value: entry.id,
                            child: Text('${entry.name} · ${entry.location}'),
                          ),
                      ],
                      onChanged: widget.controller.invitationBusy
                          ? null
                          : (value) => setState(() => selectedClinicId = value),
                    );
                  },
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(
                    labelText: 'Staff role to invite',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'doctor', child: Text('Doctor')),
                    DropdownMenuItem(
                      value: 'specialist',
                      child: Text('Specialist'),
                    ),
                  ],
                  onChanged: widget.controller.invitationBusy
                      ? null
                      : (value) => setState(() => role = value ?? 'doctor'),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Invitee email'),
              ),
              const SizedBox(height: 16),
              if (widget.controller.error != null)
                Text(
                  widget.controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              FilledButton(
                onPressed: widget.controller.invitationBusy ? null : _create,
                child: Text(
                  widget.controller.invitationBusy
                      ? 'Creating invitation…'
                      : 'Create invitation',
                ),
              ),
              if (issuedId != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  label: 'Invitation ID: $issuedId',
                  excludeSemantics: true,
                  child: SelectableText('Invitation ID: $issuedId'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: issuedId!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Invitation ID copied.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy invitation ID'),
                ),
                const Text(
                  'This ID is shown only now. Share it securely with the named invitee.',
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
