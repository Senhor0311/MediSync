import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// IDs are internal references; the directory holds approved display fields.
abstract class ClinicRepository {
  Future<List<ClinicDirectoryEntry>> listDirectory();
  Future<ClinicDetails?> getClinic(String clinicId);
  Future<void> createClinic(ClinicDraft draft);
  Future<void> updateSettings(String clinicId, ClinicSettings settings);
  Future<void> updateIdentity(String clinicId, ClinicIdentity identity);
  Future<void> archiveClinic(String clinicId, String reason);
  Future<List<ClinicStaff>> listStaff(String clinicId);
  Future<void> suspendStaff(String clinicId, String userId, String reason);
}

class ClinicStaff {
  const ClinicStaff(this.userId, this.email, this.role, this.status);
  final String userId;
  final String email;
  final String role;
  final String status;
}

class ClinicDirectoryEntry {
  const ClinicDirectoryEntry(this.id, this.name, this.category, this.location);
  final String id;
  final String name;
  final String category;
  final String location;

  static ClinicDirectoryEntry? fromData(String id, Map<String, dynamic>? data) {
    if (data == null ||
        data['clinicId'] != id ||
        data['status'] != 'active' ||
        data['displayName'] is! String ||
        data['category'] is! String ||
        data['locationLabel'] is! String) {
      return null;
    }
    return ClinicDirectoryEntry(
      id,
      data['displayName'] as String,
      data['category'] as String,
      data['locationLabel'] as String,
    );
  }
}

class ClinicIdentity {
  const ClinicIdentity(this.name, this.category, this.location);
  final String name;
  final String category;
  final String location;
}

class ClinicSettings {
  const ClinicSettings(
    this.phone,
    this.email,
    this.address,
    this.timezone,
    this.operatingHours,
    this.slotMinutes,
  );
  final String phone;
  final String email;
  final String address;
  final String timezone;
  final String operatingHours;
  final int slotMinutes;
}

class ClinicDraft {
  const ClinicDraft(this.identity, this.settings);
  final ClinicIdentity identity;
  final ClinicSettings settings;
}

class ClinicDetails {
  const ClinicDetails({
    required this.clinicId,
    required this.name,
    required this.category,
    required this.location,
    required this.settings,
    this.status = 'active',
  });
  final String clinicId;
  final String name;
  final String category;
  final String location;
  final ClinicSettings settings;
  final String status;

  static ClinicDetails? fromData(String id, Map<String, dynamic>? data) {
    if (data == null ||
        data['clinicId'] != id ||
        data['name'] is! String ||
        data['category'] is! String ||
        data['publicLocation'] is! String ||
        data['contact'] is! Map ||
        data['slotMinutes'] is! int) {
      return null;
    }
    final contact = data['contact'] as Map;
    return ClinicDetails(
      clinicId: id,
      name: data['name'] as String,
      category: data['category'] as String,
      location: data['publicLocation'] as String,
      status: data['status'] is String ? data['status'] as String : 'unknown',
      settings: ClinicSettings(
        contact['phone'] is String ? contact['phone'] as String : '',
        contact['email'] is String ? contact['email'] as String : '',
        data['address'] is String ? data['address'] as String : '',
        data['timezone'] is String ? data['timezone'] as String : '',
        data['operatingHours'] is String
            ? data['operatingHours'] as String
            : '',
        data['slotMinutes'] as int,
      ),
    );
  }
}

abstract interface class StaffAdministration {
  Future<void> restoreStaff(String clinicId, String userId, String reason);
  Future<void> publishStaff(
    String clinicId,
    ClinicStaff staff,
    String displayName,
    bool published,
  );
}

abstract interface class ClinicQueueSetup {
  Future<void> setupQueue(String clinicId);
}

abstract interface class QueueEstimateSettings {
  Future<int?> queueEstimate(String clinicId);
  Future<void> setQueueEstimate(String clinicId, int minutes);
}

class FirestoreClinicRepository
    implements
        ClinicRepository,
        StaffAdministration,
        ClinicQueueSetup,
        QueueEstimateSettings {
  const FirestoreClinicRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  @override
  Future<void> setupQueue(String clinicId) async {
    final clinic =
        (await db
                .doc('clinics/$clinicId')
                .get(const GetOptions(source: Source.server)))
            .data();
    final timezone = clinic?['timezone'];
    if (!['Africa/Johannesburg', 'UTC'].contains(timezone)) {
      throw StateError(
        'Queue setup supports Africa/Johannesburg or UTC only. A reviewed DST-aware design is required for other zones.',
      );
    }
    final ref = db.doc('queue_configs/$clinicId');
    final schedule = db.doc('clinic_schedules/$clinicId');
    if (!(await schedule.get(const GetOptions(source: Source.server))).exists) {
      await schedule.set({
        'clinicId': clinicId,
        'slotMinutes': clinic!['slotMinutes'],
        'timezone': timezone,
      });
    }
    if ((await ref.get(const GetOptions(source: Source.server))).exists) return;
    await ref.set({
      'clinicId': clinicId,
      'status': 'active',
      'utcOffsetMinutes': timezone == 'UTC' ? 0 : 120,
      'estimateMinutesPerPatient': clinic!['slotMinutes'],
    });
  }

  @override
  Future<int?> queueEstimate(String clinicId) async =>
      (await db
                  .doc('queue_configs/$clinicId')
                  .get(const GetOptions(source: Source.server)))
              .data()?['estimateMinutesPerPatient']
          as int?;
  @override
  Future<void> setQueueEstimate(String clinicId, int minutes) async {
    if (minutes < 1 || minutes > 120) throw ArgumentError('Use 1–120 minutes.');
    await db.doc('queue_configs/$clinicId').update({
      'estimateMinutesPerPatient': minutes,
    });
  }

  String get _uid {
    final uid = auth.currentUser?.uid;
    if (uid == null) throw StateError('Sign in to manage clinics.');
    return uid;
  }

  @override
  Future<List<ClinicDirectoryEntry>> listDirectory() async {
    final result = await db
        .collection('clinic_directory')
        .where('status', isEqualTo: 'active')
        .limit(50)
        .get();
    return result.docs
        .map((doc) => ClinicDirectoryEntry.fromData(doc.id, doc.data()))
        .whereType<ClinicDirectoryEntry>()
        .toList();
  }

  @override
  Future<ClinicDetails?> getClinic(String id) async {
    final snapshot = await db.doc('clinics/$id').get();
    return ClinicDetails.fromData(id, snapshot.data());
  }

  @override
  Future<void> createClinic(ClinicDraft draft) async {
    final id = db.collection('clinics').doc().id;
    final timestamp = FieldValue.serverTimestamp();
    final batch = db.batch();
    batch.set(db.doc('clinics/$id'), {
      'clinicId': id,
      'name': draft.identity.name.trim(),
      'category': draft.identity.category.trim(),
      'publicLocation': draft.identity.location.trim(),
      'contact': {
        'phone': draft.settings.phone.trim(),
        'email': draft.settings.email.trim(),
      },
      'address': draft.settings.address.trim(),
      'timezone': draft.settings.timezone.trim(),
      'operatingHours': draft.settings.operatingHours.trim(),
      'slotMinutes': draft.settings.slotMinutes,
      'status': 'active',
      'createdBy': _uid,
      'updatedBy': _uid,
      'revision': 1,
      'createdAt': timestamp,
      'updatedAt': timestamp,
    });
    batch.set(db.doc('clinic_directory/$id'), {
      'clinicId': id,
      'displayName': draft.identity.name.trim(),
      'category': draft.identity.category.trim(),
      'locationLabel': draft.identity.location.trim(),
      'status': 'active',
      'updatedAt': timestamp,
    });
    batch.set(db.doc('clinic_schedules/$id'), {
      'clinicId': id,
      'slotMinutes': draft.settings.slotMinutes,
      'timezone': draft.settings.timezone.trim(),
    });
    if ([
      'Africa/Johannesburg',
      'UTC',
    ].contains(draft.settings.timezone.trim())) {
      batch.set(db.doc('queue_configs/$id'), {
        'clinicId': id,
        'status': 'active',
        'utcOffsetMinutes': draft.settings.timezone.trim() == 'UTC' ? 0 : 120,
        'estimateMinutesPerPatient': draft.settings.slotMinutes,
      });
    }
    await batch.commit();
  }

  @override
  Future<void> updateSettings(String id, ClinicSettings settings) =>
      db.doc('clinics/$id').update({
        'contact': {
          'phone': settings.phone.trim(),
          'email': settings.email.trim(),
        },
        'address': settings.address.trim(),
        'timezone': settings.timezone.trim(),
        'operatingHours': settings.operatingHours.trim(),
        'slotMinutes': settings.slotMinutes,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': _uid,
        'revision': FieldValue.increment(1),
      });

  @override
  Future<void> updateIdentity(String id, ClinicIdentity identity) async {
    final batch = db.batch();
    final timestamp = FieldValue.serverTimestamp();
    batch.update(db.doc('clinics/$id'), {
      'name': identity.name.trim(),
      'category': identity.category.trim(),
      'publicLocation': identity.location.trim(),
      'updatedAt': timestamp,
      'updatedBy': _uid,
      'revision': FieldValue.increment(1),
    });
    batch.update(db.doc('clinic_directory/$id'), {
      'displayName': identity.name.trim(),
      'category': identity.category.trim(),
      'locationLabel': identity.location.trim(),
      'updatedAt': timestamp,
    });
    await batch.commit();
  }

  @override
  Future<void> archiveClinic(String id, String reason) async {
    final batch = db.batch();
    final timestamp = FieldValue.serverTimestamp();
    batch.update(db.doc('clinics/$id'), {
      'status': 'archived',
      'archivedBy': _uid,
      'archivedAt': timestamp,
      'archiveReason': reason.trim(),
      'updatedAt': timestamp,
      'updatedBy': _uid,
      'revision': FieldValue.increment(1),
    });
    batch.update(db.doc('clinic_directory/$id'), {
      'status': 'archived',
      'updatedAt': timestamp,
    });
    await batch.commit();
  }

  @override
  Future<List<ClinicStaff>> listStaff(String clinicId) async {
    final result = await db
        .collection('clinic_memberships/$clinicId/members')
        .where('clinicId', isEqualTo: clinicId)
        .where('staffRole', whereIn: ['doctor', 'specialist'])
        .limit(50)
        .get();
    final staff = <ClinicStaff>[];
    for (final doc in result.docs) {
      final data = doc.data();
      if (data['clinicId'] != clinicId ||
          data['userId'] != doc.id ||
          data['staffRole'] is! String ||
          data['status'] is! String) {
        continue;
      }
      var email = 'Staff member';
      final invitationId = data['invitationId'];
      if (invitationId is String) {
        try {
          final invitation = await db.doc('invitations/$invitationId').get();
          if (invitation.data()?['clinicId'] == clinicId &&
              invitation.data()?['email'] is String) {
            email = invitation.data()!['email'] as String;
          }
        } on FirebaseException catch (error) {
          if (error.code != 'permission-denied') rethrow;
        }
      }
      staff.add(
        ClinicStaff(
          doc.id,
          email,
          data['staffRole'] as String,
          data['status'] as String,
        ),
      );
    }
    return staff;
  }

  @override
  Future<void> suspendStaff(String clinicId, String userId, String reason) =>
      db.doc('clinic_memberships/$clinicId/members/$userId').update({
        'status': 'suspended',
        'suspendedBy': _uid,
        'suspendedAt': FieldValue.serverTimestamp(),
        'revision': FieldValue.increment(1),
        'suspensionReason': reason.trim(),
      });
  @override
  Future<void> restoreStaff(String clinicId, String userId, String reason) =>
      db.doc('clinic_memberships/$clinicId/members/$userId').update({
        'status': 'active',
        'restoredBy': _uid,
        'restoredAt': FieldValue.serverTimestamp(),
        'revision': FieldValue.increment(1),
        'restorationReason': reason.trim(),
      });
  @override
  Future<void> publishStaff(
    String clinicId,
    ClinicStaff staff,
    String displayName,
    bool published,
  ) async {
    if (displayName.trim().length < 2 || displayName.trim().length > 100) {
      throw ArgumentError(
        'Enter an approved public display name (2–100 characters).',
      );
    }
    final specialist = staff.role == 'specialist',
        id = '$clinicId-${staff.userId}',
        status = published ? 'active' : 'inactive';
    final batch = db.batch();
    batch.set(
      db.doc('${specialist ? 'specialist_listings' : 'doctor_listings'}/$id'),
      {
        'listingId': id,
        'clinicId': clinicId,
        specialist ? 'specialistId' : 'providerId': staff.userId,
        'displayName': displayName.trim(),
        'status': status,
      },
    );
    batch.set(db.doc('provider_directory/${staff.userId}'), {
      'providerId': staff.userId,
      'clinicId': clinicId,
      'displayName': displayName.trim(),
      'status': status,
    });
    await batch.commit();
  }
}
