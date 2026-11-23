import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'privacy_repository.dart';
import '../records/record_support.dart';
import '../records/record_repository.dart';

class CareConsentPanel extends StatefulWidget {
  const CareConsentPanel({super.key, required this.repository});
  final FirestorePrivacyRepository repository;
  @override
  State<CareConsentPanel> createState() => _CareConsentPanelState();
}

class _CareConsentPanelState extends State<CareConsentPanel> {
  List<QueryDocumentSnapshot<Map<String, dynamic>>> visits = [];
  Map<String, dynamic>? control;
  bool busy = false;
  String? message;
  String? next;
  final _providers = <String, String>{}, _clinics = <String, String>{};
  String get uid => widget.repository.auth.currentUser!.uid;
  FirebaseFirestore get db => widget.repository.db;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false}) async {
    setState(() => busy = true);
    try {
      final c =
          (await db
                  .doc('patient_controls/$uid')
                  .get(const GetOptions(source: Source.server)))
              .data();
      Query<Map<String, dynamic>> query = db
          .collection('appointments')
          .where('patientId', isEqualTo: uid)
          .where('status', whereIn: ['called', 'completed'])
          .orderBy(FieldPath.documentId)
          .limit(20);
      if (more && next != null) query = query.startAfter([next]);
      final v = await query.get(const GetOptions(source: Source.server));
      final names = FirestoreRecordRepository(db, widget.repository.auth);
      for (final visit in v.docs) {
        final data = visit.data();
        final provider = data['providerId'] as String,
            clinic = data['clinicId'] as String;
        if (!_providers.containsKey(provider)) {
          try {
            _providers[provider] =
                await names.providerName(provider) ??
                'Provider name unavailable';
          } catch (_) {
            _providers[provider] = 'Provider name unavailable';
          }
        }
        if (!_clinics.containsKey(clinic)) {
          try {
            _clinics[clinic] =
                await names.clinicName(clinic) ?? 'Clinic name unavailable';
          } catch (_) {
            _clinics[clinic] = 'Clinic name unavailable';
          }
        }
      }
      if (mounted) {
        setState(() {
          control = c;
          visits = [if (more) ...visits, ...v.docs];
          next = v.docs.length == 20 ? v.docs.last.id : null;
          message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Care permissions could not be loaded. Reconnect and refresh.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> consent(bool allow) async {
    setState(() => busy = true);
    try {
      await db.runTransaction((tx) async {
        final ref = db.doc('patient_controls/$uid'),
            old = (await tx.get(ref)).data();
        tx.set(ref, {
          'patientId': uid,
          'status': allow ? 'consented' : 'withdrawn',
          'consentVersion': (old?['consentVersion'] as int? ?? 0) + 1,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      await load();
      if (mounted) {
        setState(
          () => message = allow
              ? 'Consent recorded. Approve each encounter below. Previous grants are not revived.'
              : 'Consent withdrawn. Fresh practitioner reads are blocked; previously copied information cannot be erased.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Consent was not changed. Reconnect and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> approve(
    QueryDocumentSnapshot<Map<String, dynamic>> visit,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve exact encounter access?'),
        content: Text(
          'Allow ${_providers[visit.data()['providerId']] ?? 'the assigned provider'} at ${_clinics[visit.data()['clinicId']] ?? 'the encounter clinic'} for the visit on ${recordDate((visit.data()['startAt'] as Timestamp?)?.toDate())} to read and create records for this exact encounter, including late author corrections, for up to 24 hours. Referral creation may name a specialist for this encounter. This does not open your whole history. You may withdraw all consent here. Reference: ${visit.id}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => busy = true);
    try {
      final v = visit.data();
      final current =
          (await db
                  .doc('patient_controls/$uid')
                  .get(const GetOptions(source: Source.server)))
              .data();
      if (current?['status'] != 'consented') {
        throw StateError('Consent required');
      }
      await publishEncounterLabel(
        db,
        uid,
        v['clinicId'] as String,
        'appointment',
        visit.id,
      );
      await db
          .doc(
            'care_relationships/${v['clinicId']}/patients/$uid/practitioners/${v['providerId']}/encounters/appointment-${visit.id}',
          )
          .set({
            'clinicId': v['clinicId'],
            'patientId': uid,
            'practitionerId': v['providerId'],
            'sourceType': 'appointment',
            'sourceId': visit.id,
            'status': 'active',
            'consentVersion': current!['consentVersion'],
            'startsAt': FieldValue.serverTimestamp(),
            'expiresAt': Timestamp.fromDate(
              DateTime.now().toUtc().add(
                const Duration(hours: 23, minutes: 55),
              ),
            ),
          });
      if (mounted) {
        setState(
          () => message = 'Encounter access approved for less than 24 hours. Refresh the practitioner screen.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Approval failed. Check consent, connection, current practitioner and visit status.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
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
            'Care permissions',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            'Current consent: ${control?['status'] ?? 'not given'}. Withdrawals block new clinical reads; copies cannot be recalled.',
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => consent(true),
                child: const Text('Give new consent'),
              ),
              TextButton(
                onPressed: busy ? null : () => consent(false),
                child: const Text('Withdraw consent'),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Refresh care permissions'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (message != null) Text(message!),
          if (visits.isEmpty && !busy)
            const Text('No called or completed encounters to approve.'),
          for (final visit in visits)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Consultation ${recordDate((visit.data()['startAt'] as Timestamp?)?.toDate())}',
              ),
              subtitle: Text(
                '${_clinics[visit.data()['clinicId']] ?? 'Clinic name unavailable'} · ${_providers[visit.data()['providerId']] ?? 'Provider name unavailable'}',
              ),
              trailing: TextButton(
                onPressed: busy || control?['status'] != 'consented'
                    ? null
                    : () => approve(visit),
                child: const Text('Approve / renew access'),
              ),
            ),
          if (next != null)
            TextButton(
              onPressed: busy ? null : () => load(more: true),
              child: const Text('Load more eligible encounters'),
            ),
        ],
      ),
    ),
  );
}
