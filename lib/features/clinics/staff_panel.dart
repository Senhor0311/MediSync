import 'package:flutter/material.dart';

import 'clinic_repository.dart';

class StaffPanel extends StatefulWidget {
  const StaffPanel({
    super.key,
    required this.repository,
    required this.clinicId,
    required this.clinicName,
  });
  final ClinicRepository repository;
  final String clinicId;
  final String clinicName;

  @override
  State<StaffPanel> createState() => _StaffPanelState();
}

class _StaffPanelState extends State<StaffPanel> {
  late Future<List<ClinicStaff>> staff;
  final reason = TextEditingController();
  String? message;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    staff = widget.repository.listStaff(widget.clinicId);
  }

  @override
  void didUpdateWidget(StaffPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clinicId != widget.clinicId ||
        oldWidget.repository != widget.repository) {
      staff = widget.repository.listStaff(widget.clinicId);
    }
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> _suspend(ClinicStaff member, {bool restore = false}) async {
    reason.clear();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${restore ? 'Reactivate' : 'Suspend'} ${member.email}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              restore
                  ? 'Reactivate the same approved clinic role and permissions. This does not restore expired patient consent or change Authentication account status.'
                  : 'This preserves the staff history and stops this clinic grant. Reactivation requires a current scoped clinic administrator.',
            ),
            TextField(
              controller: reason,
              maxLength: 300,
              decoration: const InputDecoration(
                labelText: 'Reason (at least 10 characters)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(restore ? 'Reactivate staff' : 'Suspend staff'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    if (reason.text.trim().length < 10) {
      setState(() => message = 'Enter a reason of at least 10 characters.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (restore) {
        await (widget.repository as StaffAdministration).restoreStaff(
          widget.clinicId,
          member.userId,
          reason.text,
        );
      } else {
        await widget.repository.suspendStaff(
          widget.clinicId,
          member.userId,
          reason.text,
        );
      }
      if (!mounted) return;
      setState(() {
        message =
            '${member.email} was ${restore ? 'reactivated' : 'suspended'}.';
        staff = widget.repository.listStaff(widget.clinicId);
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Suspension unavailable. Check current access.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _publish(ClinicStaff member) async {
    var approvedName = '';
    final published = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Public practitioner listing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the clinic-approved public name. Only this name, role, clinic and provider identifier are published; no profile or clinical content is copied.',
            ),
            TextField(
              onChanged: (value) => approvedName = value,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: 'Approved public name (2–100 characters)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Unpublish'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    final displayName = approvedName.trim();
    if (!mounted || published == null) return;
    if (displayName.length < 2) {
      setState(() => message = 'Enter the approved public name.');
      return;
    }
    setState(() => busy = true);
    try {
      await (widget.repository as StaffAdministration).publishStaff(
        widget.clinicId,
        member,
        displayName,
        published,
      );
      if (mounted) {
        setState(
          () => message = published
              ? 'Approved listing published. Patients may discover available appointment slots.'
              : 'Listing unpublished. Existing bookings are preserved.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Publication failed. Check current clinic access and staff status.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Staffing', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 12),
      Text('Clinic: ${widget.clinicName}'),
      const SizedBox(height: 12),
      const Text(
        'Doctor and specialist grants are shown here. Clinic administrators can suspend, reactivate the same grant and approve a public directory name. Role changes require a new reviewed approval.',
      ),
      const SizedBox(height: 12),
      FutureBuilder<List<ClinicStaff>>(
        future: staff,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Text(
              snapshot.hasError
                  ? 'Staff list unavailable for your access.'
                  : 'Loading staff…',
            );
          }
          if (snapshot.data!.isEmpty) {
            return const Text('No doctors or specialists found.');
          }
          return Column(
            children: [
              for (final member in snapshot.data!)
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        title: Text(member.email),
                        subtitle: Text(
                          '${member.role == 'doctor' ? 'Doctor' : 'Specialist'} · ${member.status}',
                        ),
                      ),
                      if (member.email == 'Staff member')
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: SelectableText(
                            'Reviewed account reference: ${member.userId}',
                          ),
                        ),
                      Wrap(
                        children: [
                          if (member.status == 'active')
                            TextButton(
                              onPressed: busy ? null : () => _suspend(member),
                              child: const Text('Suspend'),
                            ),
                          if (widget.repository is StaffAdministration) ...[
                            if (member.status == 'suspended')
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _suspend(member, restore: true),
                                child: const Text('Reactivate'),
                              ),
                            TextButton(
                              onPressed: busy ? null : () => _publish(member),
                              child: const Text('Directory listing'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      if (message != null) Text(message!),
    ],
  );
}
