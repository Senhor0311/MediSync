import '../../shared/data/server_transaction.dart';
import '../appointments/appointment_repository.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class QueueConfigurationUnavailable implements Exception {
  const QueueConfigurationUnavailable();
}

class QueueAppointment {
  const QueueAppointment(
    this.id,
    this.clinicId,
    this.providerId,
    this.start,
    this.status,
    this.queueId,
  );
  final String id, clinicId, providerId, status;
  final DateTime start;
  final String? queueId;
}

class QueueEntry {
  const QueueEntry(
    this.id,
    this.stateId,
    this.appointmentId,
    this.clinicId,
    this.providerId,
    this.patientId,
    this.ticket,
    this.status, {
    this.fromCache = false,
  });
  final String id,
      stateId,
      appointmentId,
      clinicId,
      providerId,
      patientId,
      status;
  final int ticket;
  final bool fromCache;

  static QueueEntry? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null ||
        data['queueId'] != doc.id ||
        data['stateId'] is! String ||
        data['appointmentId'] is! String ||
        data['clinicId'] is! String ||
        data['providerId'] is! String ||
        data['patientId'] is! String ||
        data['ticket'] is! int ||
        data['status'] is! String) {
      return null;
    }
    return QueueEntry(
      doc.id,
      data['stateId'] as String,
      data['appointmentId'] as String,
      data['clinicId'] as String,
      data['providerId'] as String,
      data['patientId'] as String,
      data['ticket'] as int,
      data['status'] as String,
      fromCache: doc.metadata.isFromCache,
    );
  }
}

class QueueState {
  const QueueState(this.waiting, this.activeTicket, {this.fromCache = false});
  final List<int> waiting;
  final int activeTicket;
  final bool fromCache;
  int? position(int ticket) {
    final index = waiting.indexOf(ticket);
    return index < 0 ? null : index + 1 + (activeTicket > 0 ? 1 : 0);
  }
}

abstract class QueueRepository {
  Future<List<QueueAppointment>> patientAppointments();
  Future<String> clinicName(String clinicId);
  Future<String> doctorName(String clinicId, String providerId);
  Stream<QueueEntry?> entry(String queueId);
  Stream<QueueState?> state(String stateId);
  Stream<List<QueueEntry>> practitionerEntries(
    String clinicId,
    String providerId,
    String stateId,
    String status,
  );
  Future<int> estimateMinutes(String clinicId);
  Future<String> todayStateId(String clinicId, String providerId);
  Future<void> checkIn(QueueAppointment appointment);
  Future<void> cancelCheckIn(QueueEntry entry);
  Future<void> callNext(String clinicId, String providerId, String stateId);
  Future<void> complete(QueueEntry entry);
}

abstract interface class QueueVisitContext {
  Future<String?> visitReason(String appointmentId);
}

class FirestoreQueueRepository implements QueueRepository, QueueVisitContext {
  const FirestoreQueueRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;

  Future<QueueEntry?> serverEntry(String id) async => QueueEntry.fromDoc(
    await db.doc('queues/$id').get(const GetOptions(source: Source.server)),
  );

  String get _uid =>
      auth.currentUser?.uid ?? (throw StateError('Sign in required'));

  @override
  Future<String?> visitReason(String appointmentId) =>
      FirestoreAppointmentRepository(db, auth).visitReason(appointmentId);

  @override
  Future<List<QueueAppointment>> patientAppointments() async {
    final docs = await db
        .collection('appointments')
        .where('patientId', isEqualTo: _uid)
        .where('status', whereIn: ['booked', 'checked_in', 'called'])
        .where(
          'startAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(
            DateTime.now().toUtc().subtract(const Duration(days: 1)),
          ),
        )
        .orderBy('startAt')
        .limit(50)
        .get();
    return docs.docs
        .map((d) {
          final x = d.data();
          if (x['clinicId'] is! String ||
              x['providerId'] is! String ||
              x['startAt'] is! Timestamp ||
              x['status'] is! String) {
            return null;
          }
          return QueueAppointment(
            d.id,
            x['clinicId'] as String,
            x['providerId'] as String,
            (x['startAt'] as Timestamp).toDate(),
            x['status'] as String,
            x['queueId'] as String?,
          );
        })
        .whereType<QueueAppointment>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  @override
  Future<String> clinicName(String clinicId) async {
    final doc = await db.doc('clinic_directory/$clinicId').get();
    return doc.data()?['displayName'] as String? ?? 'Clinic';
  }

  @override
  Future<String> doctorName(String clinicId, String providerId) async {
    final doc = await db.doc('doctor_listings/$clinicId-$providerId').get();
    return doc.data()?['displayName'] as String? ?? 'Doctor';
  }

  @override
  Stream<QueueEntry?> entry(String queueId) => db
      .doc('queues/$queueId')
      .snapshots(includeMetadataChanges: true)
      .map(QueueEntry.fromDoc);

  @override
  Stream<QueueState?> state(String stateId) => db
      .doc('queue_states/$stateId')
      .snapshots(includeMetadataChanges: true)
      .map((doc) {
        final x = doc.data();
        if (x == null || x['waiting'] is! List || x['activeTicket'] is! int) {
          return null;
        }
        return QueueState(
          (x['waiting'] as List).whereType<int>().toList(),
          x['activeTicket'] as int,
          fromCache: doc.metadata.isFromCache,
        );
      });

  @override
  Stream<List<QueueEntry>> practitionerEntries(
    String clinicId,
    String providerId,
    String stateId,
    String status,
  ) => db
      .collection('queues')
      .where('clinicId', isEqualTo: clinicId)
      .where('providerId', isEqualTo: providerId)
      .where('stateId', isEqualTo: stateId)
      .where('status', isEqualTo: status)
      .orderBy('ticket', descending: status == 'completed')
      .limit(50)
      .snapshots(includeMetadataChanges: true)
      .map(
        (docs) =>
            docs.docs.map(QueueEntry.fromDoc).whereType<QueueEntry>().toList()
              ..sort((a, b) => a.ticket.compareTo(b.ticket)),
      );

  @override
  Future<int> estimateMinutes(String clinicId) async {
    final config = await db
        .doc('queue_configs/$clinicId')
        .get(const GetOptions(source: Source.server));
    final value = config.data()?['estimateMinutesPerPatient'];
    if (value is! int) throw StateError('Queue estimate unavailable');
    return value;
  }

  Future<int> _offset(String clinicId) async {
    final config = await db
        .doc('queue_configs/$clinicId')
        .get(const GetOptions(source: Source.server));
    final offset = config.data()?['utcOffsetMinutes'];
    if (offset is! int) throw const QueueConfigurationUnavailable();
    return offset;
  }

  @override
  Future<String> todayStateId(String clinicId, String providerId) async {
    final offset = await _offset(clinicId);
    final shifted = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().millisecondsSinceEpoch + offset * 60000,
      isUtc: true,
    );
    final start =
        DateTime.utc(
          shifted.year,
          shifted.month,
          shifted.day,
        ).millisecondsSinceEpoch -
        offset * 60000;
    return '$clinicId-$providerId-$start';
  }

  String _stateId(QueueAppointment appointment, int offset) {
    final shifted = DateTime.fromMillisecondsSinceEpoch(
      appointment.start.toUtc().millisecondsSinceEpoch + offset * 60000,
      isUtc: true,
    );
    final start =
        DateTime.utc(
          shifted.year,
          shifted.month,
          shifted.day,
        ).millisecondsSinceEpoch -
        offset * 60000;
    return '${appointment.clinicId}-${appointment.providerId}-$start';
  }

  @override
  Future<void> checkIn(QueueAppointment appointment) =>
      _checkIn(appointment, null);

  Future<void> checkInStaffManaged(
    QueueAppointment appointment,
    String patientId,
  ) => _checkIn(appointment, patientId);

  Future<void> _checkIn(
    QueueAppointment appointment,
    String? staffPatientId,
  ) async {
    final patientId = staffPatientId ?? _uid;
    final offset = await _offset(appointment.clinicId);
    final stateId = _stateId(appointment, offset);
    // Rules validate this self-owned operational link against the appointment.
    // It authorizes anonymous queue observation, never clinical access.
    if (staffPatientId == null) {
      await db.doc('queue_observers/$stateId/patients/$_uid').set({
        'appointmentId': appointment.id,
      });
    }
    final stateRef = db.doc('queue_states/$stateId');
    final appointmentRef = db.doc('appointments/${appointment.id}');
    await runServerTransaction(db, _uid, (tx) async {
      final current = await tx.get(appointmentRef);
      final state = await tx.get(stateRef);
      final x = current.data();
      if (x?['patientId'] != patientId ||
          staffPatientId != null && x?['patientKind'] != 'staff_managed' ||
          x?['status'] != 'booked' ||
          x?['clinicId'] != appointment.clinicId ||
          x?['providerId'] != appointment.providerId ||
          x?['startAt'] != Timestamp.fromDate(appointment.start)) {
        throw StateError('This appointment is no longer eligible.');
      }
      final ticket = state.exists ? state.data()!['nextTicket'] as int : 1;
      final queueId = '$stateId-$ticket';
      final fields = {
        'clinicId': appointment.clinicId,
        'providerId': appointment.providerId,
        'dayStartMillis': int.parse(stateId.split('-').last),
        'nextTicket': ticket + 1,
        'headTicket': state.data()?['headTicket'] ?? 1,
        'waiting': [...?state.data()?['waiting'] as List?, ticket],
        'activeTicket': state.data()?['activeTicket'] ?? 0,
        'changedTicket': ticket,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      tx.set(stateRef, fields);
      tx.set(db.doc('queues/$queueId'), {
        'queueId': queueId,
        'stateId': stateId,
        'appointmentId': appointment.id,
        'clinicId': appointment.clinicId,
        'providerId': appointment.providerId,
        'patientId': patientId,
        'ticket': ticket,
        'status': 'waiting',
        'checkedInAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(appointmentRef, {
        'status': 'checked_in',
        'queueId': queueId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Future<void> cancelCheckIn(QueueEntry entry) async {
    final stateRef = db.doc('queue_states/${entry.stateId}');
    final queueRef = db.doc('queues/${entry.id}');
    final appointmentRef = db.doc('appointments/${entry.appointmentId}');
    await runServerTransaction(db, _uid, (tx) async {
      final state = await tx.get(stateRef);
      final queue = await tx.get(queueRef);
      final appointment = await tx.get(appointmentRef);
      if (queue.data()?['patientId'] != _uid &&
              appointment.data()?['patientKind'] != 'staff_managed' ||
          queue.data()?['status'] != 'waiting' ||
          appointment.data()?['status'] != 'checked_in' ||
          !(state.data()?['waiting'] as List).contains(entry.ticket)) {
        throw StateError('Check-in can no longer be cancelled.');
      }
      tx.update(stateRef, {
        'waiting': (state.data()!['waiting'] as List)
            .where((ticket) => ticket != entry.ticket)
            .toList(),
        'changedTicket': entry.ticket,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(queueRef, {
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(appointmentRef, {
        'status': 'check_in_cancelled',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Future<void> callNext(
    String clinicId,
    String providerId,
    String stateId,
  ) async {
    final stateRef = db.doc('queue_states/$stateId');
    await runServerTransaction(db, _uid, (tx) async {
      final state = await tx.get(stateRef);
      final data = state.data();
      if (data?['clinicId'] != clinicId ||
          data?['providerId'] != providerId ||
          data?['activeTicket'] != 0 ||
          (data?['headTicket'] as int? ?? data?['nextTicket'] as int? ?? 1) >=
              (data?['nextTicket'] as int? ?? 1)) {
        throw StateError('No next patient is ready.');
      }
      final ticket = data!['headTicket'] as int;
      final queueRef = db.doc('queues/$stateId-$ticket');
      final queue = await tx.get(queueRef);
      final appointmentRef = db.doc(
        'appointments/${queue.data()?['appointmentId']}',
      );
      final appointment = await tx.get(appointmentRef);
      if (queue.data()?['status'] == 'cancelled') {
        tx.update(stateRef, {
          'headTicket': ticket + 1,
          'changedTicket': ticket,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }
      if (queue.data()?['status'] != 'waiting' ||
          appointment.data()?['status'] != 'checked_in') {
        throw StateError('Queue changed. Refresh and try again.');
      }
      tx.update(stateRef, {
        'waiting': (data['waiting'] as List).skip(1).toList(),
        'activeTicket': ticket,
        'headTicket': ticket + 1,
        'changedTicket': ticket,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(queueRef, {
        'status': 'called',
        'calledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(appointmentRef, {
        'status': 'called',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Future<void> complete(QueueEntry entry) async {
    final stateRef = db.doc('queue_states/${entry.stateId}');
    final queueRef = db.doc('queues/${entry.id}');
    final appointmentRef = db.doc('appointments/${entry.appointmentId}');
    await runServerTransaction(db, _uid, (tx) async {
      final state = await tx.get(stateRef);
      final queue = await tx.get(queueRef);
      final appointment = await tx.get(appointmentRef);
      if (state.data()?['activeTicket'] != entry.ticket ||
          queue.data()?['status'] != 'called' ||
          appointment.data()?['status'] != 'called') {
        throw StateError('This patient is no longer called.');
      }
      tx.update(stateRef, {
        'activeTicket': 0,
        'changedTicket': entry.ticket,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(queueRef, {
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(appointmentRef, {
        'status': 'completed',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}
