import 'package:flutter/material.dart';

import 'queue_repository.dart';

class PatientQueuePanel extends StatefulWidget {
  const PatientQueuePanel({super.key, required this.repository});
  final QueueRepository repository;

  @override
  State<PatientQueuePanel> createState() => _PatientQueuePanelState();
}

class _PatientQueuePanelState extends State<PatientQueuePanel> {
  List<QueueAppointment>? _appointments;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final value = await widget.repository.patientAppointments();
      if (mounted) setState(() => _appointments = value);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Queue information is unavailable. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkIn(QueueAppointment appointment) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.repository.checkIn(appointment);
      await _load();
      if (mounted) setState(() => _message = 'Check-in confirmed.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Check-in is unavailable. Confirm the appointment date and clinic, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(QueueEntry entry) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.repository.cancelCheckIn(entry);
      await _load();
      if (mounted) setState(() => _message = 'Check-in cancelled.');
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Check-in can no longer be cancelled.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Your check-in and queue',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Synthetic prototype: check-in records your declaration that you are at the appointment clinic. Physical presence is not verified.',
      ),
      const SizedBox(height: 8),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Text(_message!, key: const Key('queue-message')),
      TextButton(
        onPressed: _busy ? null : _load,
        child: const Text('Refresh appointments'),
      ),
      if (_appointments != null && _appointments!.isEmpty)
        const Text('No appointments to check in for.'),
      for (final appointment in _appointments ?? <QueueAppointment>[])
        _PatientAppointmentCard(
          appointment: appointment,
          repository: widget.repository,
          busy: _busy,
          checkIn: () => _checkIn(appointment),
          cancel: _cancel,
        ),
    ],
  );
}

class _PatientAppointmentCard extends StatelessWidget {
  const _PatientAppointmentCard({
    required this.appointment,
    required this.repository,
    required this.busy,
    required this.checkIn,
    required this.cancel,
  });
  final QueueAppointment appointment;
  final QueueRepository repository;
  final bool busy;
  final VoidCallback checkIn;
  final ValueChanged<QueueEntry> cancel;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<String>(
            future: repository.clinicName(appointment.clinicId),
            builder: (_, snapshot) => Text(
              snapshot.data ?? 'Clinic',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Text(_when(appointment.start)),
          FutureBuilder<String>(
            future: repository.doctorName(
              appointment.clinicId,
              appointment.providerId,
            ),
            builder: (_, snapshot) => Text(snapshot.data ?? 'Doctor'),
          ),
          if (appointment.status == 'booked') ...[
            const Text(
              'Check in on the appointment date while at this clinic.',
            ),
            FilledButton(
              onPressed: busy ? null : checkIn,
              child: const Text('Check in'),
            ),
          ] else if (appointment.queueId != null)
            StreamBuilder<QueueEntry?>(
              stream: repository.entry(appointment.queueId!),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('Queue status is unavailable.');
                }
                final entry = snapshot.data;
                if (entry == null) return const Text('Loading queue status…');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ticket #${entry.ticket}'),
                    if (entry.fromCache)
                      const Text(
                        'Showing cached queue data. Reconnect to confirm current status.',
                      ),
                    Text('Status: ${_status(entry.status)}'),
                    if (entry.status == 'waiting') ...[
                      StreamBuilder<QueueState?>(
                        stream: repository.state(entry.stateId),
                        builder: (context, state) {
                          if (state.hasError) {
                            return const Text('Queue position is unavailable.');
                          }
                          if (state.data?.fromCache == true) {
                            return const Text(
                              'Queue position is cached. Reconnect for a current estimate.',
                            );
                          }
                          final position = state.data?.position(entry.ticket);
                          if (position == null) {
                            return const Text('Updating position…');
                          }
                          return FutureBuilder<int>(
                            future: repository.estimateMinutes(entry.clinicId),
                            builder: (_, estimate) => Text(
                              estimate.hasData
                                  ? 'Position $position · Estimated wait about ${(position - 1) * estimate.data!} minutes (synthetic estimate)'
                                  : 'Position $position · Estimate unavailable',
                            ),
                          );
                        },
                      ),
                      TextButton(
                        onPressed: busy || entry.fromCache
                            ? null
                            : () => cancel(entry),
                        child: const Text('Cancel check-in'),
                      ),
                    ],
                  ],
                );
              },
            )
          else
            Text('Status: ${_status(appointment.status)}'),
        ],
      ),
    ),
  );
}

class PractitionerQueuePanel extends StatefulWidget {
  const PractitionerQueuePanel({
    super.key,
    required this.repository,
    required this.clinicId,
    required this.providerId,
    required this.clinicName,
  });
  final QueueRepository repository;
  final String clinicId, providerId, clinicName;

  @override
  State<PractitionerQueuePanel> createState() => _PractitionerQueuePanelState();
}

class _PractitionerQueuePanelState extends State<PractitionerQueuePanel> {
  String? _message;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = 'Queue updated.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Queue changed or access is unavailable. Refresh and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Queue at ${widget.clinicName}',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Text(_message!, key: const Key('queue-message')),
      FutureBuilder<String>(
        future: widget.repository.todayStateId(
          widget.clinicId,
          widget.providerId,
        ),
        builder: (context, day) {
          if (day.hasError) {
            return const Text('Queue configuration is unavailable.');
          }
          if (!day.hasData) return const CircularProgressIndicator();
          final stateId = day.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StreamBuilder<QueueState?>(
                stream: widget.repository.state(stateId),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Text('Queue state is unavailable.');
                  }
                  final state = snapshot.data;
                  if (state == null) {
                    return const Text('No patients are checked in today.');
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${state.waiting.length} waiting'),
                      if (state.fromCache)
                        const Text(
                          'Showing cached queue data. Reconnect before advancing.',
                        ),
                      FilledButton(
                        onPressed:
                            _busy ||
                                state.fromCache ||
                                state.waiting.isEmpty ||
                                state.activeTicket != 0
                            ? null
                            : () => _run(
                                () => widget.repository.callNext(
                                  widget.clinicId,
                                  widget.providerId,
                                  stateId,
                                ),
                              ),
                        child: const Text('Call next'),
                      ),
                    ],
                  );
                },
              ),
              _QueueList(
                repository: widget.repository,
                clinicId: widget.clinicId,
                providerId: widget.providerId,
                stateId: stateId,
                status: 'called',
                busy: _busy,
                complete: (entry) =>
                    _run(() => widget.repository.complete(entry)),
              ),
              _QueueList(
                repository: widget.repository,
                clinicId: widget.clinicId,
                providerId: widget.providerId,
                stateId: stateId,
                status: 'waiting',
                busy: _busy,
              ),
              _QueueList(
                repository: widget.repository,
                clinicId: widget.clinicId,
                providerId: widget.providerId,
                stateId: stateId,
                status: 'completed',
                busy: _busy,
              ),
            ],
          );
        },
      ),
    ],
  );
}

class _QueueList extends StatelessWidget {
  const _QueueList({
    required this.repository,
    required this.clinicId,
    required this.providerId,
    required this.stateId,
    required this.status,
    required this.busy,
    this.complete,
  });
  final QueueRepository repository;
  final String clinicId, providerId, stateId, status;
  final bool busy;
  final ValueChanged<QueueEntry>? complete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      Text(
        status == 'completed' ? 'Recently completed' : _status(status),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      StreamBuilder<List<QueueEntry>>(
        stream: repository.practitionerEntries(
          clinicId,
          providerId,
          stateId,
          status,
        ),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text('Queue list is unavailable.');
          }
          if (!snapshot.hasData) return const CircularProgressIndicator();
          if (snapshot.data!.isEmpty) {
            return const Text('No patients in this section.');
          }
          return Column(
            children: [
              for (final entry in snapshot.data!)
                ListTile(
                  title: Text('Patient ticket ${entry.ticket}'),
                  subtitle: Text(_status(entry.status)),
                  onTap: repository is QueueVisitContext
                      ? () async {
                          String message;
                          try {
                            final reason =
                                await (repository as QueueVisitContext)
                                    .visitReason(entry.appointmentId);
                            message = reason?.isNotEmpty == true
                                ? reason!
                                : 'No reason recorded.';
                          } catch (_) {
                            message = 'Visit reason is unavailable.';
                          }
                          if (!context.mounted) return;
                          await showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Restricted visit reason'),
                              content: Text(message),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          );
                        }
                      : null,
                  trailing: complete == null
                      ? null
                      : TextButton(
                          onPressed: busy || entry.fromCache
                              ? null
                              : () => complete!(entry),
                          child: const Text('Complete'),
                        ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

String _status(String status) => switch (status) {
  'checked_in' || 'waiting' => 'Waiting',
  'check_in_cancelled' || 'cancelled' => 'Check-in cancelled',
  'called' => 'Called',
  'completed' => 'Completed',
  _ => status,
};

String _when(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
