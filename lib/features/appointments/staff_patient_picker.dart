import 'package:flutter/material.dart';

import 'staff_patient_repository.dart';

class StaffPatientPicker extends StatefulWidget {
  const StaffPatientPicker({
    super.key,
    required this.repository,
    required this.clinicId,
    required this.onSelected,
  });
  final StaffPatientRepository repository;
  final String clinicId;
  final ValueChanged<String?> onSelected;
  @override
  State<StaffPatientPicker> createState() => _StaffPatientPickerState();
}

class _StaffPatientPickerState extends State<StaffPatientPicker> {
  final reference = TextEditingController(), label = TextEditingController();
  List<StaffPatient>? patients;
  String? selected, message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    reference.dispose();
    label.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    try {
      final rows = await widget.repository.list(widget.clinicId);
      if (mounted) {
        setState(() {
          patients = rows;
          message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Patient references unavailable. Retry.');
      }
    }
  }

  Future<void> register() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final id = await widget.repository.register(
        widget.clinicId,
        reference.text,
        label.text,
      );
      await reload();
      if (mounted) {
        setState(() {
          selected = id;
          message = 'Operational identity created.';
        });
        widget.onSelected(id);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is FormatException ? e.message : 'Reference exists or access unavailable. Use Find reference to select an existing identity; refresh after a connection failure.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> find() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final row = await widget.repository.find(widget.clinicId, reference.text);
      if (row == null) {
        if (mounted) {
          setState(
            () => message = 'No identity found for that exact reference.',
          );
        }
        return;
      }
      if (mounted) {
        setState(() {
          patients = [row, ...?patients?.where((p) => p.id != row.id)];
          selected = row.id;
        });
        widget.onSelected(row.id);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Reference lookup failed. Check the reference, access and connection.',
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
      const Text(
        'Non-app patient: operational booking/check-in only. No Auth account, clinical key, consent or account linking is created. Verify the clinic reference with the patient; matching labels do not establish identity.',
      ),
      if (patients != null)
        DropdownButtonFormField<String>(
          key: ValueKey(selected),
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Clinic patient reference',
          ),
          items: [
            for (final p in patients!)
              DropdownMenuItem(
                value: p.id,
                child: Text('${p.reference} · ${p.label}'),
              ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  setState(() => selected = value);
                  widget.onSelected(value);
                },
        ),
      TextField(
        controller: reference,
        maxLength: 16,
        decoration: const InputDecoration(
          labelText: 'Clinic reference (4–16 letters/digits)',
        ),
      ),
      TextField(
        controller: label,
        maxLength: 80,
        decoration: const InputDecoration(labelText: 'Fictional patient label'),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: busy ? null : find,
            child: const Text('Find reference'),
          ),
          OutlinedButton(
            onPressed: busy ? null : register,
            child: const Text('Register non-app patient'),
          ),
          TextButton(
            onPressed: busy ? null : reload,
            child: const Text('Refresh references'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ],
  );
}
