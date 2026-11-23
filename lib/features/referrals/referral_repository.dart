import '../../shared/data/server_transaction.dart';
import '../../shared/data/history_page.dart';
import '../encryption/clinical_crypto.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReferralPatient {
  const ReferralPatient(this.patientId, this.appointmentId, this.visitAt);
  final String patientId, appointmentId;
  final DateTime visitAt;
}

class ReferralSpecialist {
  const ReferralSpecialist(this.id, this.name, {this.clinicId});
  final String id, name;
  final String? clinicId;
  String get key => '${clinicId ?? ''}:$id';
}

class ReferralEntry {
  const ReferralEntry({
    required this.id,
    required this.clinicId,
    required this.patientId,
    required this.referringDoctorId,
    required this.specialistId,
    required this.sourceAppointmentId,
    required this.priority,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.rejectionReason,
    this.destinationClinicId,
    this.decisionAt,
    this.operationalOnly = false,
  });
  final String id, clinicId, patientId, referringDoctorId, specialistId;
  final String sourceAppointmentId, priority, reason, status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? decisionAt;
  final String? rejectionReason;
  final String? destinationClinicId;
  final bool operationalOnly;

  static ReferralEntry fromData(String id, Map<String, dynamic> data) {
    if (data['referralId'] != id ||
        data['clinicId'] is! String ||
        data['patientId'] is! String ||
        data['referringDoctorId'] is! String ||
        data['specialistId'] is! String ||
        data['sourceAppointmentId'] is! String ||
        data['priority'] is! String ||
        data['reason'] is! String ||
        data['status'] is! String ||
        data['createdAt'] is! Timestamp) {
      throw const FormatException('Invalid referral');
    }
    return ReferralEntry(
      id: id,
      clinicId: data['clinicId'] as String,
      patientId: data['patientId'] as String,
      referringDoctorId: data['referringDoctorId'] as String,
      specialistId: data['specialistId'] as String,
      sourceAppointmentId: data['sourceAppointmentId'] as String,
      priority: data['priority'] as String,
      reason: data['reason'] as String,
      status: data['status'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      rejectionReason: data['rejectionReason'] as String?,
      destinationClinicId: data['destinationClinicId'] as String?,
      decisionAt: (data['decisionAt'] as Timestamp?)?.toDate(),
    );
  }
}

abstract class ReferralRepository {
  Future<List<ReferralPatient>> doctorPatients(String clinicId);
  Future<List<ReferralSpecialist>> specialists(String clinicId);
  Future<List<ReferralEntry>> patientReferrals();
  Future<List<ReferralEntry>> doctorReferrals(
    String clinicId,
    List<ReferralPatient> patients,
  );
  Future<List<ReferralEntry>> specialistInbox(String clinicId);
  Future<String?> providerName(String id, String clinicId);
  Future<String?> clinicName(String id);
  Future<void> create({
    required String clinicId,
    required ReferralPatient patient,
    required String specialistId,
    required String priority,
    required String reason,
  });
  Future<void> decide(String id, bool accept, String rejectionReason);
  Future<void> complete(String id);
}

abstract interface class CrossClinicReferralCommands {
  Future<void> createCrossClinic({
    required String clinicId,
    required String destinationClinicId,
    required ReferralPatient patient,
    required String specialistId,
    required String priority,
    required String reason,
  });
}

class FirestoreReferralRepository
    implements
        ReferralRepository,
        CrossClinicReferralCommands,
        HistoryPager<ReferralEntry> {
  const FirestoreReferralRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;

  String get _uid =>
      auth.currentUser?.uid ?? (throw StateError('Sign in required'));

  @override
  Future<List<ReferralPatient>> doctorPatients(String clinicId) async {
    final docs = await db
        .collection('appointments')
        .where('clinicId', isEqualTo: clinicId)
        .where('providerId', isEqualTo: _uid)
        .where('status', whereIn: ['called', 'completed'])
        .orderBy('startAt', descending: true)
        .limit(50)
        .get(const GetOptions(source: Source.server));
    return docs.docs
        .where(
          (d) =>
              d.data()['patientId'] is String &&
              d.data()['startAt'] is Timestamp &&
              ['called', 'completed'].contains(d.data()['status']),
        )
        .map(
          (d) => ReferralPatient(
            d.data()['patientId'] as String,
            d.id,
            (d.data()['startAt'] as Timestamp).toDate(),
          ),
        )
        .toList()
      ..sort((a, b) => b.visitAt.compareTo(a.visitAt));
  }

  @override
  Future<List<ReferralSpecialist>> specialists(String clinicId) async {
    final clinics = await db
        .collection('clinic_directory')
        .where('status', isEqualTo: 'active')
        .limit(20)
        .get(const GetOptions(source: Source.server));
    final result = <ReferralSpecialist>[];
    for (final clinic in clinics.docs) {
      result.addAll(await _specialists(clinic.id));
    }
    return result;
  }

  Future<List<ReferralSpecialist>> _specialists(String clinicId) async {
    final docs = await db
        .collection('specialist_listings')
        .where('clinicId', isEqualTo: clinicId)
        .where('status', isEqualTo: 'active')
        .limit(50)
        .get(const GetOptions(source: Source.server));
    final current = <DocumentSnapshot<Map<String, dynamic>>>[];
    for (final candidate in docs.docs) {
      try {
        final refreshed = await candidate.reference.get(
          const GetOptions(source: Source.server),
        );
        if (refreshed.exists) current.add(refreshed);
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
      }
    }
    return current
        .where(
          (d) =>
              d.data()?['listingId'] == d.id &&
              d.data()?['specialistId'] is String &&
              d.data()?['displayName'] is String,
        )
        .map(
          (d) => ReferralSpecialist(
            d.data()!['specialistId'] as String,
            d.data()!['displayName'] as String,
            clinicId: clinicId,
          ),
        )
        .toList();
  }

  Future<ReferralEntry> _entry(String id, Map<String, dynamic> data) async {
    final decoded = Map<String, dynamic>.from(data);
    for (final field in ['reason', 'rejectionReason']) {
      if (data[field] is Map) {
        decoded[field] = (await ClinicalCrypto.read(
          Map<String, dynamic>.from(data[field] as Map),
          'referral-$field',
          id,
          data,
        ))[field];
      } else if (data[field] is String) {
        decoded[field] = 'Legacy plaintext: ${data[field]}';
      }
    }
    return ReferralEntry.fromData(id, decoded);
  }

  Future<List<ReferralEntry>> _entries(
    QuerySnapshot<Map<String, dynamic>> docs,
  ) => Future.wait(docs.docs.map((d) => _entry(d.id, d.data())));

  Future<ReferralEntry?> _operationalEntry(String id) async {
    Map<String, dynamic>? data;
    Map<String, dynamic>? pointer;
    try {
      pointer =
          (await db
                  .doc('referral_inbox/$id')
                  .get(const GetOptions(source: Source.server)))
              .data();
      data =
          (await db
                  .doc('specialist_appointments/$id')
                  .get(const GetOptions(source: Source.server)))
              .data();
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') return null;
      rethrow;
    }
    if (data == null && pointer?['patientId'] is! String) return null;
    final destination = (data?['clinicId'] ?? pointer!['clinicId']) as String;
    final operation =
        (await db
                .doc('clinic_referral_operations/$destination/items/$id')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (operation == null) return null;
    return ReferralEntry(
      id: id,
      clinicId: operation['clinicId'] as String,
      destinationClinicId: destination,
      patientId: (data?['patientId'] ?? pointer!['patientId']) as String,
      specialistId: (data?['providerId'] ?? pointer!['specialistId']) as String,
      referringDoctorId: '',
      sourceAppointmentId: '',
      priority: 'Not available in scheduling metadata',
      reason: 'Clinical context is unavailable. Scheduling metadata grants no clinical access.',
      status: operation['status'] as String,
      createdAt: ((data?['createdAt'] ?? operation['updatedAt']) as Timestamp)
          .toDate(),
      operationalOnly: true,
    );
  }

  @override
  Future<HistoryPage<ReferralEntry>> historyPage({
    String? after,
    Map<String, String> scope = const {},
  }) async {
    if (scope['role'] != 'specialist') {
      final page = await readHistoryPage(
        db.collection('referrals').where('patientId', isEqualTo: _uid),
        (id, data) => MapEntry(id, data),
        after: after,
      );
      return HistoryPage(
        await Future.wait(page.items.map((e) => _entry(e.key, e.value))),
        page.next,
      );
    }
    final pointers = await readHistoryPage(
      db
          .collection('referral_inbox')
          .where('clinicId', isEqualTo: scope['clinicId'])
          .where('specialistId', isEqualTo: _uid),
      (id, data) => id,
      after: after,
    );
    final entries = <ReferralEntry>[];
    for (final id in pointers.items) {
      try {
        final data =
            (await db
                    .doc('referrals/$id')
                    .get(const GetOptions(source: Source.server)))
                .data();
        if (data != null) entries.add(await _entry(id, data));
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        // Expired/revoked context must not leak clinical content. Continue paging pointers.
        final operational = await _operationalEntry(id);
        if (operational != null) entries.add(operational);
      }
    }
    return HistoryPage(entries, pointers.next);
  }

  @override
  Future<List<ReferralEntry>> patientReferrals() async => _entries(
    await db
        .collection('referrals')
        .where('patientId', isEqualTo: _uid)
        .limit(50)
        .get(const GetOptions(source: Source.server)),
  );

  @override
  Future<List<ReferralEntry>> doctorReferrals(
    String clinicId,
    List<ReferralPatient> patients,
  ) async {
    final result = <String, ReferralEntry>{};
    for (final patient in patients) {
      try {
        final docs = await db
            .collection('referrals')
            .where('clinicId', isEqualTo: clinicId)
            .where('patientId', isEqualTo: patient.patientId)
            .where('sourceAppointmentId', isEqualTo: patient.appointmentId)
            .where('referringDoctorId', isEqualTo: _uid)
            .limit(50)
            .get(const GetOptions(source: Source.server));
        for (final entry in await _entries(docs)) {
          result[entry.id] = entry;
        }
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        // A past operational encounter may no longer have clinical access.
      }
    }
    return result.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<ReferralEntry>> specialistInbox(String clinicId) async {
    final pointers = await db
        .collection('referral_inbox')
        .where('clinicId', isEqualTo: clinicId)
        .where('specialistId', isEqualTo: _uid)
        .limit(50)
        .get(const GetOptions(source: Source.server));
    final result = <ReferralEntry>[];
    for (final pointer in pointers.docs) {
      try {
        final data =
            (await db
                    .doc('referrals/${pointer.id}')
                    .get(const GetOptions(source: Source.server)))
                .data();
        if (data != null) {
          result.add(await _entry(pointer.id, data));
        }
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') {
          rethrow;
        }
        // A revoked care grant leaves a nonclinical pointer only.
        final operational = await _operationalEntry(pointer.id);
        if (operational != null) result.add(operational);
      }
    }
    return result..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<String?> providerName(String id, String clinicId) async {
    try {
      final data =
          (await db
                  .doc('specialist_listings/$clinicId-$id')
                  .get(const GetOptions(source: Source.server)))
              .data();
      if (data?['specialistId'] == id &&
          data?['clinicId'] == clinicId &&
          data?['displayName'] is String) {
        return data!['displayName'] as String;
      }
    } catch (_) {
      // A doctor has no specialist listing; use the approved exact-get directory.
    }
    try {
      final data =
          (await db
                  .doc('provider_directory/$id')
                  .get(const GetOptions(source: Source.server)))
              .data();
      return data?['displayName'] as String?;
    } catch (_) {
      try {
        final data =
            (await db
                    .doc('doctor_listings/$clinicId-$id')
                    .get(const GetOptions(source: Source.server)))
                .data();
        if (data?['providerId'] == id && data?['clinicId'] == clinicId) {
          return data?['displayName'] as String?;
        }
        return null;
      } catch (_) {
        return null;
      }
    }
  }

  @override
  Future<String?> clinicName(String id) async {
    try {
      final data =
          (await db
                  .doc('clinic_directory/$id')
                  .get(const GetOptions(source: Source.server)))
              .data();
      return data?['displayName'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> create({
    required String clinicId,
    required ReferralPatient patient,
    required String specialistId,
    required String priority,
    required String reason,
  }) => createCrossClinic(
    clinicId: clinicId,
    destinationClinicId: clinicId,
    patient: patient,
    specialistId: specialistId,
    priority: priority,
    reason: reason,
  );

  @override
  Future<void> createCrossClinic({
    required String clinicId,
    required String destinationClinicId,
    required ReferralPatient patient,
    required String specialistId,
    required String priority,
    required String reason,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 200 ||
        !['routine', 'urgent'].contains(priority)) {
      throw const FormatException('Enter a short fictional reason.');
    }
    final id = db.collection('referrals').doc().id;
    final grant = await db
        .doc(
          'care_relationships/$clinicId/patients/${patient.patientId}/practitioners/$_uid/encounters/appointment-${patient.appointmentId}',
        )
        .get(const GetOptions(source: Source.server));
    final now = FieldValue.serverTimestamp();
    final context = {
      'clinicId': clinicId,
      'patientId': patient.patientId,
      'destinationClinicId': destinationClinicId,
      'referringDoctorId': _uid,
      'specialistId': specialistId,
      'sourceAppointmentId': patient.appointmentId,
    };
    final encryptedReason = await ClinicalCrypto.write(
      {'reason': trimmed},
      'referral-reason',
      id,
      context,
      {_uid, specialistId, patient.patientId},
    );
    final batch = db.batch();
    batch.set(db.doc('referrals/$id'), {
      'referralId': id,
      'clinicId': clinicId,
      'patientId': patient.patientId,
      'destinationClinicId': destinationClinicId,
      'consentVersion': grant.data()?['consentVersion'],
      'referringDoctorId': _uid,
      'specialistId': specialistId,
      'sourceAppointmentId': patient.appointmentId,
      'priority': priority,
      'reason': encryptedReason,
      'status': 'pending',
      'createdAt': now,
      'updatedAt': now,
    });
    for (final scope in {clinicId, destinationClinicId}) {
      batch.set(db.doc('clinic_referral_operations/$scope/items/$id'), {
        'referralId': id,
        'clinicId': clinicId,
        'destinationClinicId': destinationClinicId,
        'status': 'pending',
        'updatedAt': now,
      });
    }
    batch.set(db.doc('referral_inbox/$id'), {
      'referralId': id,
      'clinicId': destinationClinicId,
      'specialistId': specialistId,
      'patientId': patient.patientId,
    });
    final label =
        (await db
                .doc('encounter_labels/appointment-${patient.appointmentId}')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (label != null) {
      batch.set(db.doc('encounter_labels/referral-$id'), {
        'patientId': patient.patientId,
        'clinicId': destinationClinicId,
        'encounterType': 'referral',
        'encounterId': id,
        'displayName': label['displayName'],
        'updatedAt': now,
      });
    }
    await batch.commit();
  }

  @override
  Future<void> decide(String id, bool accept, String rejectionReason) async {
    final note = rejectionReason.trim();
    if (!accept && (note.isEmpty || note.length > 160)) {
      throw const FormatException('Enter a short fictional rejection note.');
    }
    final data =
        (await db
                .doc('referrals/$id')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (data == null) throw StateError('Referral unavailable');
    final encryptedNote = accept
        ? null
        : await ClinicalCrypto.write(
            {'rejectionReason': note},
            'referral-rejectionReason',
            id,
            data,
            {
              data['patientId'] as String,
              data['referringDoctorId'] as String,
              data['specialistId'] as String,
            },
          );
    await _transition(id, {
      'status': accept ? 'accepted' : 'rejected',
      'decisionAt': FieldValue.serverTimestamp(),
      if (!accept) 'rejectionReason': encryptedNote,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> complete(String id) => _transition(id, {
    'status': 'completed',
    'completedAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  });

  /// Explicit patient action for older pointers; Rules bind the identity to
  /// this referral and preserve the assigned recipient/clinic. No care grant.
  Future<void> enableScheduling(ReferralEntry entry) => db
      .doc('referral_inbox/${entry.id}')
      .update({'patientId': entry.patientId});

  /// Completes only operational status. Rules require the named specialist,
  /// resolved reservation and reciprocal projections; no clinical read occurs.
  Future<void> completeOperational(ReferralEntry entry) async {
    final batch = db.batch();
    batch.update(db.doc('referrals/${entry.id}'), {
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (entry.destinationClinicId != null) {
      for (final scope in {entry.clinicId, entry.destinationClinicId!}) {
        batch.set(
          db.doc('clinic_referral_operations/$scope/items/${entry.id}'),
          {
            'referralId': entry.id,
            'clinicId': entry.clinicId,
            'destinationClinicId': entry.destinationClinicId,
            'status': 'completed',
            'updatedAt': FieldValue.serverTimestamp(),
          },
        );
      }
    }
    await batch.commit();
  }

  Future<void> _transition(String id, Map<String, dynamic> changes) =>
      runServerTransaction(db, _uid, (tx) async {
        final ref = db.doc('referrals/$id');
        final data = (await tx.get(ref)).data();
        if (data == null) throw StateError('Referral unavailable');
        tx.update(ref, changes);
        if (data['destinationClinicId'] != null) {
          for (final scope in {data['clinicId'], data['destinationClinicId']}) {
            tx.set(db.doc('clinic_referral_operations/$scope/items/$id'), {
              'referralId': id,
              'clinicId': data['clinicId'],
              'destinationClinicId': data['destinationClinicId'],
              'status': changes['status'],
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
        }
      });
}
