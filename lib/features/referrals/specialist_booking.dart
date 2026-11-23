import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../shared/data/server_transaction.dart';
import '../../shared/data/history_page.dart';
import 'referral_repository.dart';
import '../clinics/schedule_settings.dart';
import '../records/record_support.dart';

class SpecialistSlot {
  const SpecialistSlot(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  DateTime get start => (data['startAt'] as Timestamp).toDate();
}

class SpecialistBookingService {
  const SpecialistBookingService(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  String get uid => auth.currentUser!.uid;
  Future<Map<String, dynamic>?> appointment(String referralId) async =>
      (await db
              .doc('specialist_appointments/$referralId')
              .get(const GetOptions(source: Source.server)))
          .data();
  Future<HistoryPage<SpecialistSlot>> slots(
    ReferralEntry r,
    bool manager, {
    String? after,
  }) async {
    Query<Map<String, dynamic>> q = db
        .collection('specialist_slots')
        .where('clinicId', isEqualTo: r.destinationClinicId ?? r.clinicId)
        .where('providerId', isEqualTo: r.specialistId)
        .where('startAt', isGreaterThan: Timestamp.now());
    if (!manager) q = q.where('status', isEqualTo: 'available');
    q = q.orderBy('startAt').orderBy(FieldPath.documentId).limit(20);
    if (after != null) {
      final parts = after.split('~');
      q = q.startAfter([
        Timestamp.fromMillisecondsSinceEpoch(int.parse(parts[0])),
        parts[1],
      ]);
    }
    final result = await q.get(const GetOptions(source: Source.server));
    return HistoryPage(
      result.docs.map((d) => SpecialistSlot(d.id, d.data())).toList(),
      result.docs.length == 20
          ? '${(result.docs.last.data()['startAt'] as Timestamp).millisecondsSinceEpoch}~${result.docs.last.id}'
          : null,
    );
  }

  Future<void> addSlot(ReferralEntry r, DateTime start) async {
    final ms = start.toUtc().millisecondsSinceEpoch,
        clinic = r.destinationClinicId ?? r.clinicId;
    final settings = await ScheduleSettings.load(db, clinic);
    settings.validateStart(start);
    await db.doc('specialist_slots/$clinic-${r.specialistId}-$ms').set({
      'clinicId': clinic,
      'providerId': r.specialistId,
      'startEpochMillis': ms,
      'startAt': Timestamp.fromMillisecondsSinceEpoch(ms),
      'endAt': Timestamp.fromMillisecondsSinceEpoch(
        ms + settings.minutes * 60000,
      ),
      'status': 'available',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setUnavailable(SpecialistSlot slot, bool value) =>
      db.doc('specialist_slots/${slot.id}').update({
        'status': value ? 'unavailable' : 'available',
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> approveClinicalVisit(
    ReferralEntry referral,
    Map<String, dynamic> appointment,
  ) async {
    final source =
        (await db
                .doc('referrals/${referral.id}')
                .get(const GetOptions(source: Source.server)))
            .data();
    await publishEncounterLabel(
      db,
      uid,
      referral.destinationClinicId ?? referral.clinicId,
      'referral',
      referral.id,
    );
    final start = (appointment['startAt'] as Timestamp).toDate();
    final now = DateTime.now().toUtc();
    final maximum = start.add(const Duration(hours: 24));
    final until = now.add(const Duration(hours: 24));
    await db.doc('referrals/${referral.id}').update({
      'visitAccess': {
        'appointmentRevision': appointment['revision'],
        'consentVersion': source!['consentVersion'],
        'status': 'active',
        'approvedAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
          until.isBefore(maximum) ? until : maximum,
        ),
      },
    });
  }

  Future<void> revokeClinicalVisit(ReferralEntry referral) => db
      .doc('referrals/${referral.id}')
      .update({'visitAccessRevokedAt': FieldValue.serverTimestamp()});
  Future<void> book(
    ReferralEntry r,
    SpecialistSlot slot, {
    bool acceptReferral = false,
  }) => runServerTransaction(db, uid, (tx) async {
    final referralRef = db.doc('referrals/${r.id}'),
        source = acceptReferral ? (await tx.get(referralRef)).data() : null;
    final ref = db.doc('specialist_appointments/${r.id}'),
        old = (await tx.get(ref)).data(),
        slotRef = db.doc('specialist_slots/${slot.id}'),
        next = (await tx.get(slotRef)).data();
    final previous = old?['status'] == 'booked'
        ? (await tx.get(db.doc('specialist_slots/${old!['slotId']}'))).data()
        : null;
    if (next?['status'] != 'available' ||
        old?['slotId'] == slot.id && old?['status'] == 'booked' ||
        old?['status'] == 'completed') {
      throw StateError('Choose another available specialist time.');
    }
    if (old?['status'] == 'booked' && previous?['appointmentId'] != r.id) {
      throw StateError('Existing reservation changed. Refresh.');
    }
    if (old?['status'] == 'booked') {
      tx.update(db.doc('specialist_slots/${old!['slotId']}'), {
        'status': 'available',
        'appointmentId': FieldValue.delete(),
        'patientId': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    final revision = (old?['revision'] as int? ?? 0) + 1,
        now = FieldValue.serverTimestamp();
    if (old != null) tx.update(referralRef, {'visitAccessRevokedAt': now});
    final data = {
      'referralId': r.id,
      'clinicId': r.destinationClinicId ?? r.clinicId,
      'providerId': r.specialistId,
      'patientId': r.patientId,
      'slotId': slot.id,
      'startAt': next!['startAt'],
      'endAt': next['endAt'],
      'status': 'booked',
      'revision': revision,
      'bookedBy': old?['bookedBy'] ?? uid,
      'updatedBy': uid,
      'createdAt': old?['createdAt'] ?? now,
      'updatedAt': now,
    };
    if (acceptReferral) {
      if (source?['status'] != 'pending' || source?['specialistId'] != uid) {
        throw StateError('Refresh the pending referral before accepting it.');
      }
      tx.update(referralRef, {
        'status': 'accepted',
        'decisionAt': now,
        'updatedAt': now,
      });
      if (source!.containsKey('destinationClinicId')) {
        for (final clinic in {
          source['clinicId'],
          source['destinationClinicId'],
        }) {
          tx.set(db.doc('clinic_referral_operations/$clinic/items/${r.id}'), {
            'referralId': r.id,
            'clinicId': source['clinicId'],
            'destinationClinicId': source['destinationClinicId'],
            'status': 'accepted',
            'updatedAt': now,
          });
        }
      }
    }
    tx.update(slotRef, {
      'status': 'booked',
      'appointmentId': r.id,
      'patientId': r.patientId,
      'updatedAt': now,
    });
    tx.set(ref, data);
    tx.set(db.doc('specialist_appointment_versions/${r.id}-v$revision'), data);
  });
  Future<void> transition(ReferralEntry r, String status) =>
      runServerTransaction(db, uid, (tx) async {
        final ref = db.doc('specialist_appointments/${r.id}'),
            old = (await tx.get(ref)).data();
        if (old?['status'] != 'booked') {
          throw StateError('Refresh the current appointment.');
        }
        final slotRef = db.doc('specialist_slots/${old!['slotId']}');
        final slot = (await tx.get(slotRef)).data();
        if (slot?['appointmentId'] != r.id) {
          throw StateError('Reservation changed.');
        }
        final revision = (old['revision'] as int) + 1,
            changes = {
              'status': status,
              'revision': revision,
              'updatedBy': uid,
              'updatedAt': FieldValue.serverTimestamp(),
            };
        tx.update(ref, changes);
        tx.update(db.doc('referrals/${r.id}'), {
          'visitAccessRevokedAt': FieldValue.serverTimestamp(),
        });
        tx.set(db.doc('specialist_appointment_versions/${r.id}-v$revision'), {
          ...old,
          ...changes,
        });
        tx.update(slotRef, {
          'status': 'available',
          'appointmentId': FieldValue.delete(),
          'patientId': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
}

class SpecialistBookingPanel extends StatefulWidget {
  const SpecialistBookingPanel({
    super.key,
    required this.repository,
    required this.referral,
    required this.specialistMode,
    this.onChanged,
  });
  final FirestoreReferralRepository repository;
  final ReferralEntry referral;
  final bool specialistMode;
  final Future<void> Function()? onChanged;
  @override
  State<SpecialistBookingPanel> createState() => _SpecialistBookingPanelState();
}

class _SpecialistBookingPanelState extends State<SpecialistBookingPanel> {
  ScheduleSettings? schedule;
  late final service = SpecialistBookingService(
    widget.repository.db,
    widget.repository.auth,
  );
  bool open = false, busy = false;
  String? message, next;
  Map<String, dynamic>? appointment;
  List<SpecialistSlot> slots = [];
  Future<void> load({bool more = false}) async {
    setState(() {
      open = true;
      busy = true;
      message = null;
    });
    try {
      final settings = await ScheduleSettings.load(
        widget.repository.db,
        widget.referral.destinationClinicId ?? widget.referral.clinicId,
      );
      final a = await service.appointment(widget.referral.id),
          page = await service.slots(
            widget.referral,
            widget.specialistMode,
            after: more ? next : null,
          );
      if (mounted) {
        setState(() {
          appointment = a;
          schedule = settings;
          slots = [if (more) ...slots, ...page.items];
          next = page.next;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Specialist scheduling is unavailable. Check current referral, clinic access and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> run(Future<void> Function() action, String success) async {
    setState(() => busy = true);
    try {
      await action();
      await load();
      await widget.onChanged?.call();
      if (mounted) setState(() => message = success);
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'The change was not confirmed. Refresh before retrying. Booking needs an accepted referral, current consent, an approved clinic slot and a time within 90 days. Clinical approval is separate and available only near the visit.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() async {
    final day = await showDatePicker(
      context: context,
      firstDate: schedule!.clinicNow(),
      lastDate: schedule!.clinicNow().add(const Duration(days: 90)),
      initialDate: schedule!.clinicNow(),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch(
          ((DateTime.now().millisecondsSinceEpoch + 1800000) / 1800000).ceil() *
              1800000,
        ),
      ),
    );
    if (time == null || !mounted) return;
    await run(
      () => service.addSlot(
        widget.referral,
        schedule!.fromClinicTime(day, time.hour, time.minute),
      ),
      'Specialist availability saved.',
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: busy ? null : load,
        child: const Text('Specialist appointment'),
      ),
      if (open) ...[
        Text(
          'Specialist appointments use the clinic’s ${schedule?.minutes ?? 30}-minute grid (${schedule?.timezone ?? 'loading'}), with immutable versions. Booking up to 90 days ahead grants no clinical access. The patient may explicitly approve one window of at most 24 hours near the exact booked visit. Rescheduling, cancellation, withdrawal and expiry invalidate that visit window. The doctor FIFO queue is separate.',
        ),
        if (appointment != null)
          Text(
            'Current appointment: ${appointment!['status']} · ${schedule?.format((appointment!['startAt'] as Timestamp).toDate())} · revision ${appointment!['revision']}',
          ),
        if (appointment?['status'] == 'booked')
          Wrap(
            children: [
              if (!widget.specialistMode) ...[
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(
                          () => service.approveClinicalVisit(
                            widget.referral,
                            appointment!,
                          ),
                          'Clinical access approved for this exact visit, for at most 24 hours. Existing downloaded content cannot be recalled.',
                        ),
                  child: const Text('Approve clinical access for this visit'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(
                          () => service.revokeClinicalVisit(widget.referral),
                          'Referral clinical access revoked. Previously downloaded content cannot be recalled.',
                        ),
                  child: const Text('Revoke clinical access'),
                ),
              ],
              if ((appointment!['startAt'] as Timestamp).toDate().isAfter(
                DateTime.now(),
              ))
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(
                          () =>
                              service.transition(widget.referral, 'cancelled'),
                          'Specialist appointment cancelled; time released.',
                        ),
                  child: const Text('Cancel specialist appointment'),
                ),
              if (widget.specialistMode &&
                  !(appointment!['startAt'] as Timestamp).toDate().isAfter(
                    DateTime.now(),
                  ))
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(
                          () =>
                              service.transition(widget.referral, 'completed'),
                          'Specialist appointment completed.',
                        ),
                  child: const Text('Complete specialist appointment'),
                ),
            ],
          ),
        if (widget.specialistMode)
          OutlinedButton(
            onPressed: busy ? null : add,
            child: const Text('Add specialist time'),
          ),
        if (slots.isEmpty && !busy)
          const Text('No future specialist times on this page.'),
        for (final slot in slots)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${schedule?.format(slot.start)} · ${slot.data['status']}'),
              Wrap(
                children: [
                  if (slot.data['status'] == 'available' &&
                      (widget.referral.status == 'accepted' ||
                          widget.specialistMode &&
                              widget.referral.status == 'pending') &&
                      appointment?['status'] != 'completed')
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(
                              () => service.book(
                                widget.referral,
                                slot,
                                acceptReferral:
                                    widget.referral.status == 'pending',
                              ),
                              appointment?['status'] == 'booked'
                                  ? 'Specialist appointment rescheduled atomically.'
                                  : widget.referral.status == 'pending'
                                  ? 'Referral accepted and specialist appointment booked atomically.'
                                  : 'Specialist appointment booked.',
                            ),
                      child: Text(
                        appointment?['status'] == 'booked'
                            ? 'Reschedule here'
                            : widget.referral.status == 'pending'
                            ? 'Accept and book'
                            : 'Book specialist',
                      ),
                    ),
                  if (widget.specialistMode && slot.data['status'] != 'booked')
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(
                              () => service.setUnavailable(
                                slot,
                                slot.data['status'] == 'available',
                              ),
                              'Availability changed.',
                            ),
                      child: Text(
                        slot.data['status'] == 'available'
                            ? 'Close time'
                            : 'Reopen time',
                      ),
                    ),
                ],
              ),
            ],
          ),
        if (next != null)
          TextButton(
            onPressed: busy ? null : () => load(more: true),
            child: const Text('Load more specialist times'),
          ),
      ],
      if (busy) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ],
  );
}
