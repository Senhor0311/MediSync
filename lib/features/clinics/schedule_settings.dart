import 'package:cloud_firestore/cloud_firestore.dart';

/// Only fixed-offset zones are approved by the prototype's trusted Rules.
/// A clinic's duration/timezone cannot change after creation: a mixed grid could
/// overlap existing reservations or move an existing queue to another day.
class ScheduleSettings {
  const ScheduleSettings(this.minutes, this.timezone);
  final int minutes;
  final String timezone;
  int get offsetMinutes => timezone == 'UTC' ? 0 : 120;
  DateTime clinicNow() =>
      DateTime.now().toUtc().add(Duration(minutes: offsetMinutes));
  DateTime fromClinicTime(DateTime day, int hour, int minute) => DateTime.utc(
    day.year,
    day.month,
    day.day,
    hour,
    minute,
  ).subtract(Duration(minutes: offsetMinutes));
  String format(DateTime instant) {
    final date = instant.toUtc().add(Duration(minutes: offsetMinutes));
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} $timezone';
  }

  void validateStart(DateTime instant) {
    if (!instant.isAfter(DateTime.now()) ||
        instant.toUtc().millisecondsSinceEpoch % (minutes * 60000) != 0) {
      throw ArgumentError(
        'Choose a future start on the clinic’s $minutes-minute grid ($timezone).',
      );
    }
  }

  static Future<ScheduleSettings> load(
    FirebaseFirestore db,
    String clinic,
  ) async {
    final data =
        (await db
                .doc('clinic_schedules/$clinic')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (data != null) {
      if (![15, 20, 30, 60].contains(data['slotMinutes']) ||
          !['UTC', 'Africa/Johannesburg'].contains(data['timezone'])) {
        throw StateError('Invalid approved schedule settings.');
      }
      return ScheduleSettings(
        data['slotMinutes'] as int,
        data['timezone'] as String,
      );
    }
    // Previously created V3 clinics were Rules-constrained to 30 minutes. Their
    // queue offset was immutable. New clinics always publish the exact projection.
    final config =
        (await db
                .doc('queue_configs/$clinic')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (config?['utcOffsetMinutes'] != 0 &&
        config?['utcOffsetMinutes'] != 120) {
      throw StateError(
        'An administrator must set up this clinic schedule/queue first.',
      );
    }
    return ScheduleSettings(
      30,
      config!['utcOffsetMinutes'] == 0 ? 'UTC' : 'Africa/Johannesburg',
    );
  }
}
