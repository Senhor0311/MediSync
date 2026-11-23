import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../referrals/referral_repository.dart';
import 'records_panel.dart';
import 'record_support.dart';

/// Bounded encounter discovery; expired/missing labels never become identities.
class RecordChoiceSource {
  RecordChoiceSource(
    this.db,
    this.auth,
    this.role,
    this.clinicId,
    this.clinicLabel,
  );
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final String role, clinicId, clinicLabel;
  String? _next;
  DocumentSnapshot<Map<String, dynamic>>? _appointmentCursor;
  bool hasMore = true;
  Future<List<RecordPatientChoice>> load({bool more = false}) async {
    final rows = <RecordPatientChoice>[];
    final referrals = FirestoreReferralRepository(db, auth);
    Future<void> add(
      String patient,
      String type,
      String id,
      DateTime? visit,
    ) async {
      try {
        final label =
            (await db
                    .doc('encounter_labels/$type-$id')
                    .get(const GetOptions(source: Source.server)))
                .data();
        if (label == null ||
            label['patientId'] != patient ||
            label['clinicId'] != clinicId) {
          return;
        }
        if (type == 'referral') {
          final appointment =
              (await db
                      .doc('specialist_appointments/$id')
                      .get(const GetOptions(source: Source.server)))
                  .data();
          visit = (appointment?['startAt'] as Timestamp?)?.toDate();
        }
        rows.add(
          RecordPatientChoice(
            patient,
            '${label['displayName']} · ${recordDate(visit)} · $clinicLabel · ${type == 'appointment' ? 'Consultation' : 'Specialist visit'} · ref ${id.length > 8 ? id.substring(id.length - 8) : id}',
            encounterType: type,
            encounterId: id,
            visitAt: visit,
          ),
        );
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
      }
    }

    if (role == 'doctor') {
      var query = db
          .collection('appointments')
          .where('clinicId', isEqualTo: clinicId)
          .where('providerId', isEqualTo: auth.currentUser!.uid)
          .where('status', whereIn: ['called', 'completed'])
          .orderBy('startAt', descending: true)
          .orderBy(FieldPath.documentId, descending: true)
          .limit(20);
      if (more && _appointmentCursor != null) {
        query = query.startAfterDocument(_appointmentCursor!);
      }
      final page = await query.get(const GetOptions(source: Source.server));
      final patients = <ReferralPatient>[];
      for (final appointment in page.docs) {
        final data = appointment.data();
        if (data['patientId'] is! String) {
          continue; // Non-app identities have no clinical keys/consent.
        }
        final date = (data['startAt'] as Timestamp).toDate();
        patients.add(
          ReferralPatient(data['patientId'] as String, appointment.id, date),
        );
        await add(
          data['patientId'] as String,
          'appointment',
          appointment.id,
          date,
        );
      }
      for (final referral in await referrals.doctorReferrals(
        clinicId,
        patients,
      )) {
        if ((referral.destinationClinicId ?? referral.clinicId) == clinicId) {
          await add(referral.patientId, 'referral', referral.id, null);
        }
      }
      // Advance only after every required page read succeeds.
      _appointmentCursor = page.docs.lastOrNull;
      hasMore = page.size == 20;
    } else {
      final page = await referrals.historyPage(
        after: more ? _next : null,
        scope: {'role': 'specialist', 'clinicId': clinicId},
      );
      for (final referral in page.items) {
        if (!referral.operationalOnly) {
          await add(referral.patientId, 'referral', referral.id, null);
        }
      }
      _next = page.next;
      hasMore = page.next != null;
    }
    return rows;
  }
}
