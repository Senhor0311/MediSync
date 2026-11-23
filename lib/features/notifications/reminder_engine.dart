import 'dart:async';

class ReminderReservation {
  const ReminderReservation(this.id, this.startAt);
  final String id;
  final DateTime startAt;
}

/// Best-effort foreground timers. Every callback revalidates server state;
/// rescheduling, pause, failure and sign-out invalidate even in-flight callbacks.
class ReminderEngine {
  ReminderEngine({
    required this.validate,
    required this.deliver,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<bool> Function(ReminderReservation) validate;
  final Future<void> Function(ReminderReservation) deliver;
  final DateTime Function() now;
  final Map<String, Timer> _timers = {};
  final Set<String> _delivered = {};
  int _generation = 0;

  void replace(List<ReminderReservation> rows) {
    cancel();
    final generation = _generation;
    for (final row in rows) {
      final key = '${row.id}:${row.startAt.microsecondsSinceEpoch}';
      if (_delivered.contains(key) || !row.startAt.isAfter(now())) continue;
      final delay = row.startAt
          .subtract(const Duration(minutes: 5))
          .difference(now());
      _timers[key] = Timer(delay.isNegative ? Duration.zero : delay, () async {
        try {
          final valid = await validate(row);
          if (generation != _generation ||
              !valid ||
              !row.startAt.isAfter(now())) {
            return;
          }
          await deliver(row);
          if (generation == _generation) _delivered.add(key);
        } catch (_) {
          // Offline, denied and failed delivery are never recorded as success.
        }
      });
    }
  }

  void cancel() {
    _generation++;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  void reset() {
    cancel();
    _delivered.clear();
  }
}
