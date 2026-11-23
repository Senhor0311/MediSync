import '../../shared/data/server_transaction.dart';
import '../encryption/clinical_crypto.dart';
import '../../shared/data/history_page.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../clinics/clinic_repository.dart';
import '../clinics/schedule_settings.dart';

class DoctorListing {
  const DoctorListing(this.id, this.name, this.clinicId);
  final String id, name, clinicId;
}

class AppointmentSlot {
  const AppointmentSlot(
    this.id,
    this.clinicId,
    this.providerId,
    this.start,
    this.end,
    this.status,
  );
  final String id, clinicId, providerId, status;
  final DateTime start, end;
}

class AppointmentEntry {
  const AppointmentEntry(
    this.id,
    this.slotId,
    this.clinicId,
    this.providerId,
    this.start,
    this.status, {
    this.patientId,
    this.staffManaged = false,
  });
  final String id, slotId, clinicId, providerId, status;
  final String? patientId;
  final bool staffManaged;
  final DateTime start;
}

abstract class AppointmentRepository {
  Future<List<ClinicDirectoryEntry>> clinics();
  Future<List<DoctorListing>> doctors(String clinicId);
  Future<List<AppointmentSlot>> availableSlots(
    String clinicId,
    String providerId,
  );
  Future<List<AppointmentSlot>> staffSlots(String clinicId, String providerId);
  Future<List<AppointmentEntry>> patientAppointments();
  Future<void> book(AppointmentSlot slot);
  Future<void> cancel(AppointmentEntry appointment);
  Future<void> reschedule(AppointmentEntry appointment, AppointmentSlot slot);
  Future<void> createSlot(String clinicId, String providerId, DateTime start);
  Future<void> setUnavailable(AppointmentSlot slot, bool unavailable);
}

abstract interface class AppointmentCommands {
  Future<void> bookForPatient(
    AppointmentSlot slot,
    String? patientId,
    String reason,
  );
  Future<List<AppointmentEntry>> clinicAppointments(String clinicId);
  Future<String?> visitReason(String appointmentId);
}

class FirestoreAppointmentRepository
    implements
        AppointmentRepository,
        AppointmentCommands,
        HistoryPager<AppointmentEntry> {
  const FirestoreAppointmentRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;

  String get _uid =>
      auth.currentUser?.uid ?? (throw StateError('Sign in required'));

  @override
  Future<List<ClinicDirectoryEntry>> clinics() async {
    final result = await db
        .collection('clinic_directory')
        .where('status', isEqualTo: 'active')
        .limit(50)
        .get();
    return result.docs
        .map((d) => ClinicDirectoryEntry.fromData(d.id, d.data()))
        .whereType<ClinicDirectoryEntry>()
        .toList();
  }

  @override
  Future<List<DoctorListing>> doctors(String clinicId) async {
    final result = await db
        .collection('doctor_listings')
        .where('clinicId', isEqualTo: clinicId)
        .where('status', isEqualTo: 'active')
        .limit(50)
        .get();
    final current = <DocumentSnapshot<Map<String, dynamic>>>[];
    for (final candidate in result.docs) {
      try {
        // Exact reads recheck active membership; discovery never grants access.
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
              d.data()?['clinicId'] == clinicId &&
              d.data()?['providerId'] is String &&
              d.data()?['displayName'] is String,
        )
        .map(
          (d) => DoctorListing(
            d.data()!['providerId'] as String,
            d.data()!['displayName'] as String,
            clinicId,
          ),
        )
        .toList();
  }

  AppointmentSlot? _slot(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data['clinicId'] is! String ||
        data['providerId'] is! String ||
        data['startAt'] is! Timestamp ||
        data['endAt'] is! Timestamp ||
        data['status'] is! String) {
      return null;
    }
    return AppointmentSlot(
      d.id,
      data['clinicId'] as String,
      data['providerId'] as String,
      (data['startAt'] as Timestamp).toDate(),
      (data['endAt'] as Timestamp).toDate(),
      data['status'] as String,
    );
  }

  @override
  Future<List<AppointmentSlot>> availableSlots(
    String clinicId,
    String providerId,
  ) async {
    final result = await db
        .collection('availability_slots')
        .where('clinicId', isEqualTo: clinicId)
        .where('providerId', isEqualTo: providerId)
        .where('status', isEqualTo: 'available')
        .where('startAt', isGreaterThan: Timestamp.now())
        .limit(50)
        .get();
    return result.docs.map(_slot).whereType<AppointmentSlot>().toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<List<AppointmentSlot>> staffSlots(
    String clinicId,
    String providerId,
  ) async {
    final result = await db
        .collection('availability_slots')
        .where('clinicId', isEqualTo: clinicId)
        .where('providerId', isEqualTo: providerId)
        .limit(50)
        .get();
    return result.docs.map(_slot).whereType<AppointmentSlot>().toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<HistoryPage<AppointmentEntry>> historyPage({
    String? after,
    Map<String, String> scope = const {},
  }) {
    final clinicId = scope['clinicId'];
    Query<Map<String, dynamic>> query = db
        .collection('appointments')
        .where(
          clinicId == null ? 'patientId' : 'clinicId',
          isEqualTo: clinicId ?? _uid,
        );
    if (scope['providerId'] != null) {
      query = query.where('providerId', isEqualTo: scope['providerId']);
    }
    return readHistoryPage(
      query,
      (id, data) => AppointmentEntry(
        id,
        data['slotId'] as String,
        data['clinicId'] as String,
        data['providerId'] as String,
        (data['startAt'] as Timestamp).toDate(),
        data['status'] as String,
        patientId: data['patientId'] as String?,
        staffManaged: data['patientKind'] == 'staff_managed',
      ),
      after: after,
    );
  }

  @override
  Future<List<AppointmentEntry>> patientAppointments() => _entries(
    db.collection('appointments').where('patientId', isEqualTo: _uid).limit(50),
  );

  @override
  Future<List<AppointmentEntry>> clinicAppointments(String clinicId) =>
      _entries(
        db
            .collection('appointments')
            .where('clinicId', isEqualTo: clinicId)
            .limit(50),
      );

  Future<List<AppointmentEntry>> _entries(
    Query<Map<String, dynamic>> query,
  ) async {
    final result = await query.get(const GetOptions(source: Source.server));
    return result.docs
        .where(
          (d) =>
              d.data()['slotId'] is String &&
              d.data()['clinicId'] is String &&
              d.data()['providerId'] is String &&
              d.data()['startAt'] is Timestamp &&
              d.data()['status'] is String,
        )
        .map(
          (d) => AppointmentEntry(
            d.id,
            d.data()['slotId'] as String,
            d.data()['clinicId'] as String,
            d.data()['providerId'] as String,
            (d.data()['startAt'] as Timestamp).toDate(),
            d.data()['status'] as String,
            patientId: d.data()['patientId'] as String?,
            staffManaged: d.data()['patientKind'] == 'staff_managed',
          ),
        )
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<void> book(AppointmentSlot slot) => bookForPatient(slot, null, '');

  @override
  Future<void> bookForPatient(
    AppointmentSlot slot,
    String? patientId,
    String reason,
  ) => _book(slot, patientId, reason, false);

  Future<void> bookStaffManaged(AppointmentSlot slot, String patientId) =>
      _book(slot, patientId, '', true);

  Future<void> _book(
    AppointmentSlot slot,
    String? patientId,
    String reason,
    bool staffManaged,
  ) async {
    final uid = patientId ?? _uid;
    if (!RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(uid) ||
        reason.trim().length > 200) {
      throw const FormatException(
        'Use a valid synthetic patient ID and short reason.',
      );
    }
    final appointmentRef = db.collection('appointments').doc();
    final encryptedReason = staffManaged
        ? null
        : await ClinicalCrypto.write(
            {'reason': reason.trim()},
            'appointment-reason',
            appointmentRef.id,
            {
              'patientId': uid,
              'providerId': slot.providerId,
              'clinicId': slot.clinicId,
            },
            {uid, slot.providerId},
          );
    final slotRef = db.doc('availability_slots/${slot.id}');
    await runServerTransaction(db, _uid, (tx) async {
      final current = await tx.get(slotRef);
      final data = current.data();
      if (data == null ||
          data['status'] != 'available' ||
          data['clinicId'] != slot.clinicId ||
          data['providerId'] != slot.providerId ||
          (data['startAt'] as Timestamp).toDate().isBefore(DateTime.now())) {
        throw StateError('This time is no longer available.');
      }
      tx.update(slotRef, {
        'status': 'booked',
        'appointmentId': appointmentRef.id,
        'patientId': uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(appointmentRef, {
        if (staffManaged) 'patientKind': 'staff_managed',
        'appointmentId': appointmentRef.id,
        'slotId': slot.id,
        'clinicId': slot.clinicId,
        'providerId': slot.providerId,
        'patientId': uid,
        'startAt': data['startAt'],
        'bookedBy': _uid,
        'endAt': data['endAt'],
        'status': 'booked',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!staffManaged) {
        tx.set(db.doc('private_appointment_payloads/${appointmentRef.id}'), {
          'appointmentId': appointmentRef.id,
          'reason': encryptedReason,
          'authorId': _uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  @override
  Future<String?> visitReason(String appointmentId) async {
    final appointment =
        (await db
                .doc('appointments/$appointmentId')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (appointment?['patientKind'] == 'staff_managed') {
      return 'Non-app patient: this workflow stores operational bookings only, without clinical content.';
    }
    final raw =
        (await db
                .doc('private_appointment_payloads/$appointmentId')
                .get(const GetOptions(source: Source.server)))
            .data()?['reason'];
    if (raw is! Map) {
      return raw == null ? null : 'Legacy plaintext reason: $raw';
    }
    return (await ClinicalCrypto.read(
          Map<String, dynamic>.from(raw),
          'appointment-reason',
          appointmentId,
          {
            'patientId': appointment!['patientId'],
            'providerId': appointment['providerId'],
            'clinicId': appointment['clinicId'],
          },
        ))['reason']
        as String?;
  }

  @override
  Future<void> cancel(AppointmentEntry appointment) async {
    final appointmentRef = db.doc('appointments/${appointment.id}');
    final slotRef = db.doc('availability_slots/${appointment.slotId}');
    await runServerTransaction(db, _uid, (tx) async {
      final entry = await tx.get(appointmentRef);
      final slot = await tx.get(slotRef);
      if (entry.data()?['status'] != 'booked' ||
          slot.data()?['appointmentId'] != appointment.id) {
        throw StateError('This booking can no longer be cancelled.');
      }
      tx.update(appointmentRef, {
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(slotRef, {
        'status': 'available',
        'appointmentId': FieldValue.delete(),
        'patientId': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Future<void> reschedule(
    AppointmentEntry appointment,
    AppointmentSlot slot,
  ) async {
    if (appointment.clinicId != slot.clinicId ||
        appointment.providerId != slot.providerId ||
        appointment.slotId == slot.id) {
      throw ArgumentError('Choose another time with the same doctor.');
    }
    final uid = appointment.patientId ?? _uid;
    final oldRef = db.doc('appointments/${appointment.id}');
    final oldSlotRef = db.doc('availability_slots/${appointment.slotId}');
    final newSlotRef = db.doc('availability_slots/${slot.id}');
    final newRef = db.collection('appointments').doc();
    final oldReason = uid == _uid
        ? await visitReason(appointment.id) ?? ''
        : '';
    final encryptedReason = appointment.staffManaged
        ? null
        : await ClinicalCrypto.write(
            {'reason': oldReason},
            'appointment-reason',
            newRef.id,
            {
              'patientId': uid,
              'providerId': slot.providerId,
              'clinicId': slot.clinicId,
            },
            {uid, slot.providerId},
          );
    await runServerTransaction(db, _uid, (tx) async {
      final old = (await tx.get(oldRef)).data();
      final oldSlot = (await tx.get(oldSlotRef)).data();
      final next = (await tx.get(newSlotRef)).data();
      if (old?['patientId'] != uid ||
          old?['status'] != 'booked' ||
          oldSlot?['appointmentId'] != appointment.id ||
          next?['status'] != 'available' ||
          next?['clinicId'] != appointment.clinicId ||
          next?['providerId'] != appointment.providerId ||
          next?['startAt'] is! Timestamp ||
          !(next!['startAt'] as Timestamp).toDate().isAfter(DateTime.now())) {
        throw StateError(
          'This appointment cannot be rescheduled to that time.',
        );
      }
      tx.update(oldRef, {
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(oldSlotRef, {
        'status': 'available',
        'appointmentId': FieldValue.delete(),
        'patientId': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(newSlotRef, {
        'status': 'booked',
        'appointmentId': newRef.id,
        'patientId': uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(newRef, {
        if (appointment.staffManaged) 'patientKind': 'staff_managed',
        'appointmentId': newRef.id,
        'slotId': slot.id,
        'clinicId': appointment.clinicId,
        'providerId': appointment.providerId,
        'patientId': uid,
        'startAt': next['startAt'],
        'bookedBy': _uid,
        'endAt': next['endAt'],
        'status': 'booked',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!appointment.staffManaged) {
        tx.set(db.doc('private_appointment_payloads/${newRef.id}'), {
          'appointmentId': newRef.id,
          'reason': encryptedReason,
          'authorId': _uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  @override
  Future<void> createSlot(
    String clinicId,
    String providerId,
    DateTime start,
  ) async {
    final millis = start.toUtc().millisecondsSinceEpoch;
    final settings = await ScheduleSettings.load(db, clinicId);
    settings.validateStart(start);
    final id = '$clinicId-$providerId-$millis';
    await db.doc('availability_slots/$id').set({
      'clinicId': clinicId,
      'providerId': providerId,
      'startEpochMillis': millis,
      'startAt': Timestamp.fromMillisecondsSinceEpoch(millis),
      'endAt': Timestamp.fromMillisecondsSinceEpoch(
        millis + settings.minutes * 60000,
      ),
      'status': 'available',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> setUnavailable(AppointmentSlot slot, bool unavailable) =>
      db.doc('availability_slots/${slot.id}').update({
        'status': unavailable ? 'unavailable' : 'available',
        'updatedAt': FieldValue.serverTimestamp(),
      });
}
