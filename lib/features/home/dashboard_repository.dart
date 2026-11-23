import 'clinic_operations_repository.dart';
import 'platform_metrics_repository.dart';
import '../appointments/appointment_repository.dart';
import '../clinics/clinic_repository.dart';
import '../privacy/privacy_repository.dart';
import '../queue/queue_repository.dart';
import '../referrals/referral_repository.dart';

class DashboardItem {
  const DashboardItem(this.title, this.subtitle, this.section);
  final String title, subtitle, section;
}

class DashboardSnapshot {
  const DashboardSnapshot(
    this.metrics,
    this.items,
    this.emptyMessage, {
    this.coverage,
  });
  final Map<String, int> metrics;
  final List<DashboardItem> items;
  final String emptyMessage;
  final String? coverage;
}

abstract class DashboardRepository {
  Future<DashboardSnapshot> load(String role, String? clinicId, String uid);
}

/// Uses the same scoped reads as the feature screens. Counts describe the
/// bounded loaded set, never a global user or clinical aggregate.
class ScopedDashboardRepository implements DashboardRepository {
  const ScopedDashboardRepository(
    this.appointments,
    this.queues,
    this.referrals,
    this.clinics,
    this.privacy, {
    this.operations,
    this.platformMetrics,
  });
  final AppointmentRepository appointments;
  final QueueRepository queues;
  final ReferralRepository referrals;
  final ClinicRepository clinics;
  final PrivacyRepository privacy;
  final ClinicOperationsRepository? operations;
  final PlatformMetricsRepository? platformMetrics;

  @override
  Future<DashboardSnapshot> load(
    String role,
    String? clinicId,
    String uid,
  ) async {
    if (role == 'patient') {
      final visits = await appointments.patientAppointments();
      final upcoming = visits
          .where(
            (v) =>
                ['booked', 'checked_in', 'called'].contains(v.status) &&
                v.start.isAfter(DateTime.now()),
          )
          .toList();
      final directory = await clinics.listDirectory();
      String name(String id) =>
          directory.where((c) => c.id == id).firstOrNull?.name ?? 'Clinic';
      return DashboardSnapshot(
        {
          'Upcoming': upcoming.length,
          'Completed': visits.where((v) => v.status == 'completed').length,
        },
        [
          for (final visit in upcoming.take(3))
            DashboardItem(
              name(visit.clinicId),
              '${_when(visit.start)} · ${visit.status}',
              'appointments',
            ),
        ],
        'No upcoming appointments.',
      );
    }
    if (role == 'doctor') {
      final stateId = await queues.todayStateId(clinicId!, uid);
      final waiting = await queues
          .practitionerEntries(clinicId, uid, stateId, 'waiting')
          .first;
      final patients = await referrals.doctorPatients(clinicId);
      final sent = await referrals.doctorReferrals(clinicId, patients);
      return DashboardSnapshot(
        {'Waiting': waiting.length, 'Referrals sent': sent.length},
        [
          for (final entry in waiting.take(3))
            DashboardItem(
              'Ticket #${entry.ticket}',
              'Checked in for consultation',
              'queue',
            ),
        ],
        'No patients waiting.',
      );
    }
    if (role == 'specialist') {
      final inbox = await referrals.specialistInbox(clinicId!);
      return DashboardSnapshot(
        {
          'Pending': inbox.where((r) => r.status == 'pending').length,
          'Accepted': inbox.where((r) => r.status == 'accepted').length,
        },
        [
          for (final referral in inbox.take(3))
            DashboardItem(
              '${referral.priority == 'urgent' ? 'Urgent' : 'Routine'} referral',
              referral.status,
              'referrals',
            ),
        ],
        'No authorized referrals.',
      );
    }
    if (role == 'admin') {
      final staff = await clinics.listStaff(clinicId!);
      final daily = await operations?.load(clinicId) ?? <String, int>{};
      return DashboardSnapshot(
        {
          ...daily,
          'Doctors': staff
              .where((s) => s.role == 'doctor' && s.status == 'active')
              .length,
          'Specialists': staff
              .where((s) => s.role == 'specialist' && s.status == 'active')
              .length,
        },
        const [
          DashboardItem(
            'Invite clinic staff',
            'Invite staff and manage publication. Patients approve exact clinical encounters.',
            'team',
          ),
        ],
        '',
      );
    }
    final directory = await clinics.listDirectory();
    final requests = await privacy.reviewQueue();
    final snapshot = await platformMetrics?.load();
    return DashboardSnapshot(
      {
        'Active clinics (loaded)': directory.length,
        'Privacy requests (loaded)': requests.length,
        ...?snapshot?.counts,
      },
      [
        for (final clinic in directory.take(3))
          DashboardItem(clinic.name, clinic.location, 'clinics'),
      ],
      'No active clinics.',
      coverage: snapshot?.coverage,
    );
  }
}

String _when(DateTime date) =>
    '${date.toLocal().day}/${date.toLocal().month}/${date.toLocal().year} ${date.toLocal().hour.toString().padLeft(2, '0')}:${date.toLocal().minute.toString().padLeft(2, '0')}';
