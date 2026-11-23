import 'package:cloud_firestore/cloud_firestore.dart';

class PlatformMetrics {
  const PlatformMetrics(this.counts, this.coverage);
  final Map<String, int> counts;
  final String coverage;
}

abstract interface class PlatformMetricsRepository {
  Future<PlatformMetrics> load();
}

class FirestorePlatformMetricsRepository implements PlatformMetricsRepository {
  const FirestorePlatformMetricsRepository(this.db);
  final FirebaseFirestore db;
  @override
  Future<PlatformMetrics> load() async {
    final row =
        (await db
                .doc('platform_metrics/current')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (row == null) {
      return const PlatformMetrics(
        {},
        'Global profile/membership snapshot is unavailable. A reviewed operator can generate one on demand; no background service or global user directory is exposed.',
      );
    }
    final counts = row['counts'];
    const labels = {
      'profiles_active': 'Active profiles (snapshot)',
      'profiles_suspended': 'Suspended profiles (snapshot)',
      'profiles_disabled': 'Disabled profiles (snapshot)',
      'profiles_deleting': 'Profiles in erasure (snapshot)',
      'active_memberships_clinic_admin':
          'Active clinic-admin grants (snapshot)',
      'active_memberships_doctor': 'Active doctor grants (snapshot)',
      'active_memberships_specialist': 'Active specialist grants (snapshot)',
      'clinics_active': 'Active clinics (snapshot)',
      'clinics_archived': 'Archived clinics (snapshot)',
    };
    final observed = row['observedAt'];
    if (counts is! Map || observed is! Timestamp) {
      throw const FormatException('Invalid metrics snapshot');
    }
    return PlatformMetrics(
      {
        for (final entry in labels.entries)
          if (counts[entry.key] is int && counts[entry.key] >= 0)
            entry.value: counts[entry.key] as int,
      },
      'Operator snapshot at ${observed.toDate().toLocal()}. Membership counts are grants, not unique people. Other overview counts cover up to 50 loaded rows per query. Refreshing this screen does not regenerate the operator snapshot.',
    );
  }
}
