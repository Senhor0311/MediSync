import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../referrals/referral_repository.dart';

/// Generic workflow metadata only; clinical text never enters notifications.
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.section,
    required this.changedAt,
    this.sourceKind,
    this.sourceId,
    this.status,
    this.read = false,
    this.historyId,
  });

  final String id, title, body, section;
  final DateTime changedAt;
  final String? sourceKind, sourceId, status, historyId;
  final bool read;
}

abstract class NotificationRepository {
  Future<List<NotificationItem>> load(String role, String? clinicId);
}

class NotificationPage {
  const NotificationPage(this.items, this.cursor);
  final List<NotificationItem> items;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
}

abstract interface class NotificationHistory implements NotificationRepository {
  Future<NotificationPage> history(
    String role,
    String? clinicId, {
    DocumentSnapshot<Map<String, dynamic>>? after,
  });
  Future<void> markRead(NotificationItem item, bool read);
}

class FirestoreNotificationRepository implements NotificationHistory {
  const FirestoreNotificationRepository(this.db, this.auth);

  final FirebaseFirestore db;
  final FirebaseAuth auth;

  @override
  Future<List<NotificationItem>> load(String role, String? clinicId) async {
    final uid = auth.currentUser?.uid;
    if (uid == null) throw StateError('Sign in required');
    if (role != 'patient' &&
        (clinicId == null || !['doctor', 'specialist'].contains(role))) {
      return [];
    }

    final items = <NotificationItem>[];
    final doctorPatients = <ReferralPatient>[];
    if (role == 'patient' || role == 'doctor') {
      final query = db.collection('appointments');
      final result = role == 'patient'
          ? await query
                .where('patientId', isEqualTo: uid)
                .orderBy('updatedAt', descending: true)
                .limit(50)
                .get(const GetOptions(source: Source.server))
          : await query
                .where('clinicId', isEqualTo: clinicId)
                .where('providerId', isEqualTo: uid)
                .orderBy('updatedAt', descending: true)
                .limit(50)
                .get(const GetOptions(source: Source.server));
      for (final doc in result.docs) {
        final data = doc.data();
        // The Stage 7/8 contract is required. Legacy operational documents
        // are not treated as notifications.
        if (data['appointmentId'] != doc.id ||
            data['slotId'] is! String ||
            data['providerId'] is! String ||
            data['patientId'] is! String ||
            data['clinicId'] is! String ||
            data['startAt'] is! Timestamp ||
            data['endAt'] is! Timestamp ||
            data['createdAt'] is! Timestamp ||
            data['updatedAt'] is! Timestamp ||
            (role == 'patient' && data['patientId'] != uid) ||
            (role == 'doctor' &&
                (data['providerId'] != uid || data['clinicId'] != clinicId))) {
          continue;
        }
        final item = appointmentNotification(
          doc.id,
          data['status'],
          role,
          (data['updatedAt'] as Timestamp).toDate(),
        );
        if (item != null) items.add(item);
        if (role == 'doctor') {
          doctorPatients.add(
            ReferralPatient(
              data['patientId'] as String,
              doc.id,
              (data['startAt'] as Timestamp).toDate(),
            ),
          );
        }
      }
    }

    final referrals = FirestoreReferralRepository(db, auth);
    final List<ReferralEntry> entries;
    if (role == 'patient') {
      entries = await referrals.patientReferrals();
    } else if (role == 'specialist') {
      entries = await referrals.specialistInbox(clinicId!);
    } else {
      entries = [];
      for (final patient in {
        for (final appointment in doctorPatients)
          appointment.patientId: appointment,
      }.values) {
        try {
          entries.addAll(await referrals.doctorReferrals(clinicId!, [patient]));
        } on FirebaseException catch (error) {
          if (error.code != 'permission-denied') rethrow;
          // A revoked care grant removes that patient's referral cards.
        }
      }
    }
    for (final entry in entries) {
      if (role == 'patient' && entry.patientId != uid ||
          role == 'doctor' &&
              (entry.referringDoctorId != uid || entry.clinicId != clinicId) ||
          role == 'specialist' &&
              (entry.specialistId != uid ||
                  (entry.destinationClinicId ?? entry.clinicId) != clinicId)) {
        continue;
      }
      final item = referralNotification(
        entry.id,
        entry.status,
        role,
        entry.updatedAt ?? entry.createdAt,
      );
      if (item != null) items.add(item);
    }
    if (role == 'patient' || role == 'specialist') {
      Query<Map<String, dynamic>> query = db.collection(
        'specialist_appointments',
      );
      query = role == 'patient'
          ? query.where('patientId', isEqualTo: uid)
          : query
                .where('providerId', isEqualTo: uid)
                .where('clinicId', isEqualTo: clinicId);
      final page = await query
          .orderBy('updatedAt', descending: true)
          .limit(50)
          .get(const GetOptions(source: Source.server));
      for (final doc in page.docs) {
        final row = doc.data();
        if (row['updatedAt'] is! Timestamp) continue;
        final item = specialistNotification(
          doc.id,
          row['status'],
          role,
          (row['updatedAt'] as Timestamp).toDate(),
        );
        if (item != null) items.add(item);
      }
    }
    // Transactions preserve an existing read flag when a state is observed
    // repeatedly or by concurrent devices. No fan-out to other users exists.
    for (final item in items) {
      await observe(item, role, clinicId);
    }
    return items..sort((a, b) => b.changedAt.compareTo(a.changedAt));
  }

  Future<bool> observe(
    NotificationItem item,
    String role,
    String? clinicId,
  ) async {
    final uid = auth.currentUser?.uid;
    if (uid == null) return false;
    final id = notificationEventId(item, role, clinicId);
    final ref = db
        .collection('notification_history')
        .doc(uid)
        .collection('items')
        .doc(id);
    try {
      await db.runTransaction((tx) async {
        if ((await tx.get(ref)).exists) return;
        tx.set(ref, {
          'kind': item.sourceKind,
          'sourceId': item.sourceId,
          'status': item.status,
          'sourceAt': Timestamp.fromDate(item.changedAt),
          'role': role,
          'clinicId': clinicId ?? '',
          'observedAt': FieldValue.serverTimestamp(),
          'read': false,
        });
      });
    } on FirebaseException catch (error) {
      // A transition/revocation between the query and write must fail closed.
      if (error.code != 'permission-denied') rethrow;
      return false;
    }
    return true;
  }

  @override
  Future<NotificationPage> history(
    String role,
    String? clinicId, {
    DocumentSnapshot<Map<String, dynamic>>? after,
  }) async {
    final uid = auth.currentUser?.uid;
    if (uid == null) throw StateError('Sign in required');
    Query<Map<String, dynamic>> query = db
        .collection('notification_history')
        .doc(uid)
        .collection('items')
        .where('role', isEqualTo: role)
        .where('clinicId', isEqualTo: clinicId ?? '')
        .orderBy('observedAt', descending: true)
        .limit(20);
    if (after != null) query = query.startAfterDocument(after);
    final result = await query.get(const GetOptions(source: Source.server));
    final items = <NotificationItem>[];
    for (final doc in result.docs) {
      final data = doc.data();
      final time = data['sourceAt'];
      if (time is! Timestamp || data['sourceId'] is! String) continue;
      final item = switch (data['kind']) {
        'appointment' => appointmentNotification(
          data['sourceId'],
          data['status'],
          role,
          time.toDate(),
        ),
        'referral' => referralNotification(
          data['sourceId'],
          data['status'],
          role,
          time.toDate(),
        ),
        'specialist' => specialistNotification(
          data['sourceId'],
          data['status'],
          role,
          time.toDate(),
        ),
        _ => null,
      };
      if (item != null) {
        items.add(
          NotificationItem(
            id: item.id,
            title: item.title,
            body: item.body,
            section: item.section,
            changedAt: item.changedAt,
            sourceKind: item.sourceKind,
            sourceId: item.sourceId,
            status: item.status,
            historyId: doc.id,
            read: data['read'] == true,
          ),
        );
      }
    }
    return NotificationPage(
      items,
      result.docs.length == 20 ? result.docs.last : null,
    );
  }

  @override
  Future<void> markRead(NotificationItem item, bool read) async {
    final uid = auth.currentUser?.uid;
    if (uid == null || item.historyId == null) {
      throw StateError('Stored alert required');
    }
    await db.doc('notification_history/$uid/items/${item.historyId}').update({
      'read': read,
    });
  }
}

String notificationEventId(
  NotificationItem item,
  String role,
  String? clinicId,
) =>
    '${item.sourceKind}-${item.sourceId}-${item.changedAt.millisecondsSinceEpoch}-$role-${clinicId ?? 'own'}';

NotificationItem? appointmentNotification(
  String id,
  Object? status,
  String role,
  DateTime changedAt,
) {
  final title = switch (status) {
    'booked' => 'Appointment booked',
    'cancelled' => 'Appointment cancelled',
    'checked_in' => 'Queue check-in recorded',
    'called' => 'Queue turn called',
    'completed' => 'Queue visit completed',
    'check_in_cancelled' => 'Queue check-in cancelled',
    _ => null,
  };
  if (title == null || (role != 'patient' && role != 'doctor')) return null;
  final queue = [
    'checked_in',
    'called',
    'completed',
    'check_in_cancelled',
  ].contains(status);
  final section = queue
      ? 'queue'
      : role == 'doctor'
      ? 'schedule'
      : 'appointments';
  return NotificationItem(
    id: 'appointment:$id',
    title: title,
    body:
        'Open ${queue
            ? 'queue'
            : role == 'doctor'
            ? 'schedule'
            : 'appointments'} for the current status.',
    section: section,
    changedAt: changedAt,
    sourceKind: 'appointment',
    sourceId: id,
    status: status as String,
  );
}

NotificationItem? referralNotification(
  String id,
  Object? status,
  String role,
  DateTime changedAt,
) {
  if (!['patient', 'doctor', 'specialist'].contains(role)) return null;
  final title = switch (status) {
    'pending' => 'Referral pending',
    'accepted' => 'Referral accepted',
    'rejected' => 'Referral rejected',
    'completed' => 'Referral completed',
    _ => null,
  };
  if (title == null) return null;
  return NotificationItem(
    id: 'referral:$id',
    title: title,
    body: 'Open referrals for the current status.',
    section: 'referrals',
    changedAt: changedAt,
    sourceKind: 'referral',
    sourceId: id,
    status: status as String,
  );
}

NotificationItem? specialistNotification(
  String id,
  Object? status,
  String role,
  DateTime changedAt,
) {
  if (!['patient', 'specialist'].contains(role)) return null;
  final title = switch (status) {
    'booked' => 'Specialist appointment booked',
    'cancelled' => 'Specialist appointment cancelled',
    'completed' => 'Specialist visit completed',
    _ => null,
  };
  if (title == null) return null;
  return NotificationItem(
    id: 'specialist:$id',
    title: title,
    body: 'Open referrals for the current appointment status.',
    section: 'referrals',
    changedAt: changedAt,
    sourceKind: 'specialist',
    sourceId: id,
    status: status as String,
  );
}
