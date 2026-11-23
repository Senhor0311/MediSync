import 'package:cloud_firestore/cloud_firestore.dart';

abstract interface class ClinicOperationsRepository {
  Future<Map<String, int>> load(String clinicId);
}

/// Bounded operational counts. No clinical referral document is read.
class FirestoreClinicOperationsRepository
    implements ClinicOperationsRepository {
  const FirestoreClinicOperationsRepository(this.db);
  final FirebaseFirestore db;

  @override
  Future<Map<String, int>> load(String clinicId) async {
    final config = await db
        .doc('queue_configs/$clinicId')
        .get(const GetOptions(source: Source.server));
    final offset = config.data()?['utcOffsetMinutes'];
    if (offset is! int) throw StateError('Clinic day configuration required');
    final local = DateTime.now().toUtc().add(Duration(minutes: offset));
    final start = DateTime.utc(
      local.year,
      local.month,
      local.day,
    ).subtract(Duration(minutes: offset));
    final visits = await db
        .collection('appointments')
        .where('clinicId', isEqualTo: clinicId)
        .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where(
          'startAt',
          isLessThan: Timestamp.fromDate(start.add(const Duration(days: 1))),
        )
        .orderBy('startAt')
        .limit(50)
        .get(const GetOptions(source: Source.server));
    final pending = await db
        .collection('clinic_referral_operations/$clinicId/items')
        .where('status', isEqualTo: 'pending')
        .limit(50)
        .get(const GetOptions(source: Source.server));
    final specialistVisits = await db
        .collection('specialist_appointments')
        .where('clinicId', isEqualTo: clinicId)
        .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where(
          'startAt',
          isLessThan: Timestamp.fromDate(start.add(const Duration(days: 1))),
        )
        .orderBy('startAt')
        .limit(50)
        .get(const GetOptions(source: Source.server));
    return {
      'Appointments today': visits.size + specialistVisits.size,
      'Specialist appointments today': specialistVisits.size,
      'Waiting today': visits.docs
          .where((row) => row.data()['status'] == 'checked_in')
          .length,
      'Pending referrals': pending.size,
    };
  }
}
