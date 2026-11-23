import '../encryption/clinical_crypto.dart';
import '../../shared/data/history_page.dart';

import 'package:flutter/material.dart';

import 'referral_repository.dart';
import 'record_sharing.dart';
import 'specialist_booking.dart';

class ReferralsPanel extends StatefulWidget {
  const ReferralsPanel({
    super.key,
    required this.repository,
    required this.role,
    this.clinicId,
    this.clinicName = 'Clinic',
  });
  final ReferralRepository repository;
  final String role;
  final String? clinicId;
  final String clinicName;

  @override
  State<ReferralsPanel> createState() => _ReferralsPanelState();
}

class _ReferralsPanelState extends State<ReferralsPanel> {
  final _reason = TextEditingController();
  List<ReferralEntry>? _entries;
  List<ReferralPatient> _patients = [];
  List<ReferralSpecialist> _specialists = [];
  final Map<String, String> _clinicNames = {};
  final Map<String, String> _providerNames = {};
  String? _appointmentId, _specialistId, _message;
  String _priority = 'routine';
  String? _next;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      List<ReferralEntry> entries;
      final repository = widget.repository;
      HistoryPage<ReferralEntry>? page;
      if (widget.role != 'doctor' &&
          repository is HistoryPager<ReferralEntry>) {
        page = await (repository as HistoryPager<ReferralEntry>).historyPage(
          after: more ? _next : null,
          scope: {
            'role': widget.role,
            if (widget.clinicId != null) 'clinicId': widget.clinicId!,
          },
        );
      }
      if (widget.role == 'doctor') {
        final patients = await widget.repository.doctorPatients(
          widget.clinicId!,
        );
        final specialists = await widget.repository.specialists(
          widget.clinicId!,
        );
        for (final specialist in specialists) {
          final destination = specialist.clinicId;
          if (destination != null && !_clinicNames.containsKey(destination)) {
            _clinicNames[destination] =
                await widget.repository.clinicName(destination) ??
                'Destination clinic';
          }
        }
        entries = await widget.repository.doctorReferrals(
          widget.clinicId!,
          patients,
        );
        if (mounted) {
          setState(() {
            _patients = patients;
            _specialists = specialists;
          });
        }
      } else if (widget.role == 'specialist') {
        entries =
            page?.items ??
            await widget.repository.specialistInbox(widget.clinicId!);
      } else {
        entries = page?.items ?? await widget.repository.patientReferrals();
      }
      for (final entry in entries) {
        if (entry.destinationClinicId != null) {
          _clinicNames[entry.destinationClinicId!] =
              await widget.repository.clinicName(entry.destinationClinicId!) ??
              'Destination clinic';
        }
        if (!_clinicNames.containsKey(entry.clinicId)) {
          _clinicNames[entry.clinicId] =
              await widget.repository.clinicName(entry.clinicId) ?? 'Clinic';
        }
        for (final id in [entry.referringDoctorId, entry.specialistId]) {
          if (id.isEmpty) continue;
          if (!_providerNames.containsKey(id)) {
            _providerNames[id] =
                await widget.repository.providerName(id, entry.clinicId) ??
                'Practitioner';
          }
        }
      }
      if (mounted) {
        setState(() {
          _entries = {
            for (final row in [...?(more ? _entries : null), ...entries])
              row.id: row,
          }.values.toList();
          _next = page?.next;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Referrals are unavailable. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _create() async {
    final patient = _patients
        .where((p) => p.appointmentId == _appointmentId)
        .firstOrNull;
    if (patient == null || _specialistId == null) {
      setState(() => _message = 'Choose an appointment and specialist.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final specialist = _specialists.firstWhere((s) => s.key == _specialistId);
      final repository = widget.repository;
      if (repository is CrossClinicReferralCommands) {
        await (repository as CrossClinicReferralCommands).createCrossClinic(
          clinicId: widget.clinicId!,
          destinationClinicId: specialist.clinicId ?? widget.clinicId!,
          patient: patient,
          specialistId: specialist.id,
          priority: _priority,
          reason: _reason.text,
        );
      } else {
        await repository.create(
          clinicId: widget.clinicId!,
          patient: patient,
          specialistId: specialist.id,
          priority: _priority,
          reason: _reason.text,
        );
      }
      _reason.clear();
      await _load();
      if (mounted) {
        setState(() => _message = 'Referral sent.');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is ClinicalCryptoFailure ? error.message : 'Referral could not be sent. Confirm source encounter approval and destination membership.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _reject(ReferralEntry entry) async {
    var rejectionNote = '';
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject referral'),
        content: TextField(
          onChanged: (value) => rejectionNote = value,
          maxLength: 160,
          decoration: const InputDecoration(
            labelText: 'Short fictional rejection note',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, rejectionNote),
            child: const Text('Confirm rejection'),
          ),
        ],
      ),
    );
    if (note != null && note.trim().isNotEmpty && mounted) {
      await _change(entry, 'reject', note);
    }
  }

  Future<void> _change(
    ReferralEntry entry,
    String action, [
    String note = '',
  ]) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (action == 'scheduling' &&
          widget.repository is FirestoreReferralRepository) {
        await (widget.repository as FirestoreReferralRepository)
            .enableScheduling(entry);
      } else if (action == 'complete') {
        final repository = widget.repository;
        if (repository is FirestoreReferralRepository) {
          await repository.completeOperational(entry);
        } else {
          await repository.complete(entry.id);
        }
      } else {
        await widget.repository.decide(entry.id, action == 'accept', note);
      }
      await _load();
      if (mounted) {
        setState(
          () => _message = action == 'scheduling'
              ? 'Specialist scheduling enabled without clinical access.'
              : 'Referral updated.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is ClinicalCryptoFailure ? error.message : 'Referral could not be updated. Finish or cancel any booked specialist appointment, then refresh and check its current status.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Referrals', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 12),
      if (_busy) const LinearProgressIndicator(key: Key('referral-loading')),
      if (_message != null) Text(_message!, key: const Key('referral-message')),
      if (_entries == null && !_busy)
        TextButton(onPressed: _load, child: const Text('Retry')),
      if (widget.role == 'doctor' && _entries != null) ...[
        Text(
          'New referral · ${widget.clinicName}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Synthetic clinical content only. Choose an approved source encounter and a named specialist at the destination clinic. Only this referral context is shared.',
        ),
        if (_patients.isEmpty)
          const Text('No eligible existing appointments are available.'),
        if (_patients.isNotEmpty)
          DropdownButtonFormField<String>(
            key: const Key('referral-patient'),
            isExpanded: true,
            initialValue: _appointmentId,
            decoration: const InputDecoration(labelText: 'Patient appointment'),
            items: [
              for (final p in _patients)
                DropdownMenuItem(
                  value: p.appointmentId,
                  child: Text('Visit ${_when(p.visitAt)}'),
                ),
            ],
            onChanged: _busy ? null : (v) => setState(() => _appointmentId = v),
          ),
        if (_specialists.isEmpty)
          const Text('No approved specialists are listed for this clinic.'),
        if (_specialists.isNotEmpty)
          DropdownButtonFormField<String>(
            key: const Key('referral-specialist'),
            isExpanded: true,
            initialValue: _specialistId,
            decoration: const InputDecoration(labelText: 'Specialist'),
            items: [
              for (final s in _specialists)
                DropdownMenuItem(
                  value: s.key,
                  child: Text(
                    '${s.name}${s.clinicId == null ? '' : ' · ${_clinicNames[s.clinicId] ?? 'Destination clinic'}'}',
                  ),
                ),
            ],
            onChanged: _busy ? null : (v) => setState(() => _specialistId = v),
          ),
        DropdownButtonFormField<String>(
          initialValue: _priority,
          decoration: const InputDecoration(labelText: 'Priority'),
          items: const [
            DropdownMenuItem(value: 'routine', child: Text('Routine')),
            DropdownMenuItem(value: 'urgent', child: Text('Urgent')),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() => _priority = v ?? 'routine'),
        ),
        TextField(
          controller: _reason,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'Short fictional reason',
          ),
        ),
        FilledButton(
          onPressed: _busy || _patients.isEmpty || _specialists.isEmpty
              ? null
              : _create,
          child: const Text('Send referral'),
        ),
        const SizedBox(height: 20),
      ],
      if (_entries != null && _entries!.isEmpty)
        const Text('No referrals to show.'),
      if (_next != null)
        OutlinedButton(
          onPressed: _busy ? null : () => _load(more: true),
          child: const Text('Load more referrals'),
        ),
      for (final entry in _entries ?? <ReferralEntry>[])
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_clinicNames[entry.clinicId] ?? widget.clinicName} · ${entry.status.toUpperCase()}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'From ${_providerNames[entry.referringDoctorId] ?? 'Doctor'} to ${_providerNames[entry.specialistId] ?? 'Specialist'}',
                ),
                if (entry.destinationClinicId != null)
                  Text(
                    'Destination: ${_clinicNames[entry.destinationClinicId] ?? 'Clinic'} · Shares this referral context only',
                  ),
                Text('Priority: ${entry.priority} · ${_when(entry.createdAt)}'),
                Text('Reason: ${entry.reason}'),
                if (entry.rejectionReason != null)
                  Text('Rejection: ${entry.rejectionReason}'),
                if (widget.role == 'patient' &&
                    entry.status == 'accepted' &&
                    widget.repository is FirestoreReferralRepository)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _change(entry, 'scheduling'),
                    child: const Text('Enable specialist scheduling'),
                  ),
                if (widget.repository is FirestoreReferralRepository &&
                    !entry.operationalOnly &&
                    ['patient', 'specialist'].contains(widget.role))
                  ReferralRecordSharing(
                    key: ValueKey('share-${entry.id}'),
                    repository:
                        widget.repository as FirestoreReferralRepository,
                    referral: entry,
                    patientMode: widget.role == 'patient',
                  ),
                if (widget.repository is FirestoreReferralRepository &&
                    ['patient', 'specialist'].contains(widget.role) &&
                    (entry.operationalOnly ||
                        ['accepted', 'completed'].contains(entry.status) ||
                        widget.role == 'specialist' &&
                            entry.status == 'pending'))
                  SpecialistBookingPanel(
                    key: ValueKey('booking-${entry.id}'),
                    repository:
                        widget.repository as FirestoreReferralRepository,
                    referral: entry,
                    specialistMode: widget.role == 'specialist',
                    onChanged: () => _load(),
                  ),
                if (widget.role == 'specialist' &&
                    entry.status == 'pending') ...[
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _change(entry, 'accept'),
                        child: const Text('Accept'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _reject(entry),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
                if (widget.role == 'specialist' && entry.status == 'accepted')
                  TextButton(
                    onPressed: _busy ? null : () => _change(entry, 'complete'),
                    child: const Text('Mark completed'),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}

String _when(DateTime date) {
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
