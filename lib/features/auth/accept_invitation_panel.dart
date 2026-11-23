import 'package:flutter/material.dart';

import 'auth_controller.dart';

class AcceptInvitationPanel extends StatefulWidget {
  const AcceptInvitationPanel({
    super.key,
    required this.controller,
    this.initialInvitationId,
    this.onAccepted,
  });
  final AuthController controller;
  final String? initialInvitationId;
  final VoidCallback? onAccepted;

  @override
  State<AcceptInvitationPanel> createState() => _AcceptInvitationPanelState();
}

class _AcceptInvitationPanelState extends State<AcceptInvitationPanel> {
  final invitationId = TextEditingController();

  @override
  void initState() {
    super.initState();
    invitationId.text = widget.initialInvitationId ?? '';
  }

  Future<void> _accept() async {
    if (await widget.controller.acceptInvitation(invitationId.text.trim())) {
      widget.onAccepted?.call();
    }
  }

  @override
  void dispose() {
    invitationId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Accept another clinic invitation',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter an invitation ID sent to your verified email address.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: invitationId,
            decoration: const InputDecoration(labelText: 'Invitation ID'),
          ),
          if (widget.controller.error != null)
            Text(
              widget.controller.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _accept,
            child: const Text('Accept invitation'),
          ),
        ],
      ),
    ),
  );
}
