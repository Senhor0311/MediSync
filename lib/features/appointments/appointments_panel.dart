import '../encryption/clinical_crypto.dart';
import '../../shared/data/history_page.dart';

import 'package:flutter/material.dart';

import 'appointment_repository.dart';
import '../clinics/clinic_repository.dart';
import '../queue/queue_repository.dart';
import 'staff_patient_repository.dart';
import 'staff_patient_picker.dart';
import '../clinics/schedule_settings.dart';

class AppointmentsPanel extends StatefulWidget {
  const AppointmentsPanel({
    super.key,
    required this.repository,
    this.assistedClinicId,
    this.assistedProviderId,
  });
  final AppointmentRepository repository;
  final String? assistedClinicId;
  final String? assistedProviderId;
  @override
  State<AppointmentsPanel> createState() => _AppointmentsPanelState();
}

class _AppointmentsPanelState extends State<AppointmentsPanel> {
  List<ClinicDirectoryEntry>? _clinics;
  List<DoctorListing>? _doctors;
  List<AppointmentSlot>? _slots;
  List<AppointmentEntry>? _appointments;
  String? _category, _clinicId, _doctorId, _message;
  String? _next;
  int _loadGeneration = 0;
  bool _busy = false;
  bool _staffManaged = false;
  String? _staffPatientId;
  final _reason = TextEditingController();
  final _patientId = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    _patientId.dispose();
    super.dispose();
  }

  Future<List<AppointmentEntry>> _list() async {
    final repository = widget.repository;
    if (repository is HistoryPager<AppointmentEntry>) {
      final page = await (repository as HistoryPager<AppointmentEntry>)
          .historyPage(
            scope: {
              if (widget.assistedClinicId != null)
                'clinicId': widget.assistedClinicId!,
              if (widget.assistedProviderId != null)
                'providerId': widget.assistedProviderId!,
            },
          );
      _next = page.next;
      return page.items;
    }
    return widget.assistedClinicId == null
        ? repository.patientAppointments()
        : (repository as AppointmentCommands).clinicAppointments(
            widget.assistedClinicId!,
          );
  }

  Future<void> _more() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final page = await (widget.repository as HistoryPager<AppointmentEntry>)
          .historyPage(
            after: _next,
            scope: {
              if (widget.assistedClinicId != null)
                'clinicId': widget.assistedClinicId!,
              if (widget.assistedProviderId != null)
                'providerId': widget.assistedProviderId!,
            },
          );
      if (mounted) {
        setState(() {
          final rows = {
            for (final row in [...?_appointments, ...page.items]) row.id: row,
          };
          _appointments = rows.values.toList();
          _next = page.next;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'More appointments could not be loaded. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AppointmentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistedClinicId != widget.assistedClinicId ||
        oldWidget.assistedProviderId != widget.assistedProviderId ||
        oldWidget.repository != widget.repository) {
      _clinics = null;
      _appointments = null;
      _doctors = null;
      _slots = null;
      _clinicId = null;
      _doctorId = null;
      _category = null;
      _next = null;
      _staffManaged = false;
      _staffPatientId = null;
      _patientId.clear();
      _reason.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final clinics = await widget.repository.clinics();
      final appointments = await _list();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _clinics = clinics
            .where(
              (c) =>
                  widget.assistedClinicId == null ||
                  c.id == widget.assistedClinicId,
            )
            .toList();
        _appointments = appointments;
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _message = 'Appointments are unavailable. Try again.');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _selectClinic(String? id) async {
    setState(() {
      _clinicId = id;
      _doctorId = null;
      _doctors = null;
      _slots = null;
      _message = null;
    });
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final allDoctors = await widget.repository.doctors(id);
      final doctors = allDoctors
          .where(
            (d) =>
                widget.assistedProviderId == null ||
                d.id == widget.assistedProviderId,
          )
          .toList();
      if (mounted && _clinicId == id) setState(() => _doctors = doctors);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Doctor listings are unavailable. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _selectDoctor(String? id) async {
    setState(() {
      _doctorId = id;
      _slots = null;
      _message = null;
    });
    if (id == null || _clinicId == null) return;
    setState(() => _busy = true);
    try {
      final slots = await widget.repository.availableSlots(_clinicId!, id);
      if (mounted && _doctorId == id) setState(() => _slots = slots);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Available times could not be loaded. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _book(AppointmentSlot slot) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final repository = widget.repository;
      if (_staffManaged && repository is FirestoreAppointmentRepository) {
        if (_staffPatientId == null) {
          throw StateError('Select a non-app patient reference.');
        }
        await repository.bookStaffManaged(slot, _staffPatientId!);
      } else if (repository is AppointmentCommands) {
        await (repository as AppointmentCommands).bookForPatient(
          slot,
          widget.assistedClinicId == null ? null : _patientId.text.trim(),
          _reason.text,
        );
      } else {
        await repository.book(slot);
      }
      final appointments = await _list();
      final slots = await widget.repository.availableSlots(
        slot.clinicId,
        slot.providerId,
      );
      if (!mounted) return;
      setState(() {
        _appointments = appointments;
        _slots = slots;
        _message =
            'Booking confirmed at ${_clinicName(slot.clinicId)} with ${_doctorName(slot.providerId)} on ${_when(slot.start)}.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is ClinicalCryptoFailure ? error.message : 'That time could not be booked. Refresh available times and try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _guestQueue(AppointmentEntry entry, bool cancel) async {
    final repository = widget.repository;
    if (repository is! FirestoreAppointmentRepository) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final queue = FirestoreQueueRepository(repository.db, repository.auth);
      if (cancel) {
        final data = (await repository.db.doc('appointments/${entry.id}').get())
            .data();
        final id = data?['queueId'] as String?;
        if (id == null) throw StateError('Refresh the appointment.');
        final item = await queue.serverEntry(id);
        if (item == null) throw StateError('Queue entry unavailable.');
        await queue.cancelCheckIn(item);
      } else {
        await queue.checkInStaffManaged(
          QueueAppointment(
            entry.id,
            entry.clinicId,
            entry.providerId,
            entry.start,
            entry.status,
            null,
          ),
          entry.patientId!,
        );
      }
      await _load();
      if (mounted) {
        setState(
          () => _message = cancel
              ? 'Non-app check-in cancelled. Ticket retained for FIFO processing.'
              : 'Non-app patient checked in to the same FIFO queue.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Queue change not confirmed. Refresh and check the service day, check-in window, connection and access before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(AppointmentEntry entry) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.repository.cancel(entry);
      final appointments = await _list();
      if (!mounted) return;
      setState(() {
        _appointments = appointments;
      });
      if (_clinicId == entry.clinicId && _doctorId == entry.providerId) {
        await _selectDoctor(_doctorId);
      }
      if (mounted) setState(() => _message = 'Appointment cancelled.');
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'This appointment could not be cancelled.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _reschedule(AppointmentEntry entry) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final slots = await widget.repository.availableSlots(
        entry.clinicId,
        entry.providerId,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final slot = await showDialog<AppointmentSlot>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Choose a new time'),
          children: [
            if (slots.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No other times are available. Your current booking is unchanged.',
                ),
              ),
            for (final slot in slots)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, slot),
                child: Text(_when(slot.start)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Keep current booking'),
            ),
          ],
        ),
      );
      if (slot == null || !mounted) return;
      setState(() => _busy = true);
      await widget.repository.reschedule(entry, slot);
      await _load();
      if (_clinicId == entry.clinicId && _doctorId == entry.providerId) {
        await _selectDoctor(_doctorId);
      }
      if (mounted) {
        setState(
          () => _message = 'Appointment rescheduled. The previous booking is recorded as cancelled.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is ClinicalCryptoFailure ? error.message : 'Rescheduling failed. Refresh to check your current booking before trying again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _clinicName(String id) {
    for (final clinic in _clinics ?? <ClinicDirectoryEntry>[]) {
      if (clinic.id == id) return clinic.name;
    }
    return 'Clinic';
  }

  String _doctorName(String id) {
    for (final doctor in _doctors ?? <DoctorListing>[]) {
      if (doctor.id == id) return doctor.name;
    }
    return 'Doctor';
  }

  @override
  Widget build(BuildContext context) {
    final categories = (_clinics ?? []).map((c) => c.category).toSet().toList()
      ..sort();
    final visibleClinics = (_clinics ?? [])
        .where((c) => c.category == _category)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.assistedClinicId == null
              ? 'Book an appointment'
              : 'Staff-assisted appointments',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        if (widget.assistedClinicId != null &&
            widget.repository is FirestoreAppointmentRepository)
          SwitchListTile(
            title: const Text('Book for a non-app patient'),
            value: _staffManaged,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _staffManaged = value;
                    _staffPatientId = null;
                  }),
          ),
        if (_staffManaged &&
            widget.assistedClinicId != null &&
            widget.repository is FirestoreAppointmentRepository)
          StaffPatientPicker(
            key: ValueKey(widget.assistedClinicId),
            repository: StaffPatientRepository(
              (widget.repository as FirestoreAppointmentRepository).db,
              (widget.repository as FirestoreAppointmentRepository).auth,
            ),
            clinicId: widget.assistedClinicId!,
            onSelected: (id) => _staffPatientId = id,
          ),
        if (widget.assistedClinicId != null && !_staffManaged)
          TextField(
            controller: _patientId,
            decoration: const InputDecoration(
              labelText: 'Synthetic patient account ID',
              helperText: 'Use the account ID from the local seed or Auth emulator. No patient directory is exposed.',
            ),
          ),
        if (!_staffManaged)
          TextField(
            controller: _reason,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'Minimal fictional visit reason (optional)',
            ),
          ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_message!, key: const Key('appointment-message')),
          ),
        if (_clinics == null && !_busy)
          FilledButton(onPressed: _load, child: const Text('Retry')),
        if (_clinics != null) ...[
          if (_clinics!.isEmpty) const Text('No clinics are available.'),
          if (categories.isNotEmpty)
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Clinic category'),
              items: [
                for (final c in categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: _busy
                  ? null
                  : (c) => setState(() {
                      _category = c;
                      _clinicId = null;
                      _doctorId = null;
                      _doctors = null;
                      _slots = null;
                    }),
            ),
          if (_category != null)
            DropdownButtonFormField<String>(
              key: ValueKey('clinic:$_category'),
              isExpanded: true,
              initialValue: _clinicId,
              decoration: const InputDecoration(labelText: 'Clinic'),
              items: [
                for (final c in visibleClinics)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text('${c.name} · ${c.location}'),
                  ),
              ],
              onChanged: _busy ? null : _selectClinic,
            ),
          if (_doctors != null) ...[
            if (_doctors!.isEmpty)
              const Text('No approved doctors are listed for this clinic.'),
            if (_doctors!.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey('doctor:$_clinicId'),
                isExpanded: true,
                initialValue: _doctorId,
                decoration: const InputDecoration(labelText: 'Doctor'),
                items: [
                  for (final d in _doctors!)
                    DropdownMenuItem(value: d.id, child: Text(d.name)),
                ],
                onChanged: _busy ? null : _selectDoctor,
              ),
          ],
          if (_slots != null) ...[
            const SizedBox(height: 16),
            Text(
              'Available times',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_slots!.isEmpty)
              const Text(
                'No times are available. Choose another doctor or try later.',
              ),
            for (final slot in _slots!)
              if (slot.start.isAfter(DateTime.now()))
                ListTile(
                  title: Text(_when(slot.start)),
                  trailing: FilledButton(
                    onPressed: _busy ? null : () => _book(slot),
                    child: const Text('Confirm booking'),
                  ),
                ),
          ],
        ],
        const SizedBox(height: 24),
        Text(
          widget.assistedClinicId == null
              ? 'Your appointments'
              : 'Clinic appointments',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (_appointments != null && _appointments!.isEmpty)
          const Text('No appointments yet.'),
        if (_next != null)
          OutlinedButton(
            onPressed: _busy ? null : _more,
            child: const Text('Load more appointments'),
          ),
        for (final entry in _appointments ?? <AppointmentEntry>[])
          ListTile(
            title: Text(
              '${_clinicName(entry.clinicId)} · ${_when(entry.start)}',
            ),
            subtitle: Text(
              '${_doctorName(entry.providerId)} · ${entry.status}${widget.assistedClinicId == null ? '' : ' · Patient ${entry.patientId ?? 'unavailable'}'}',
            ),
            onTap:
                widget.repository is AppointmentCommands &&
                    widget.assistedClinicId == null
                ? () async {
                    try {
                      final reason =
                          await (widget.repository as AppointmentCommands)
                              .visitReason(entry.id);
                      if (!context.mounted) return;
                      await showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Visit reason'),
                          content: Text(
                            reason?.isNotEmpty == true
                                ? reason!
                                : 'No reason recorded.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => _message = 'Visit reason is unavailable.',
                        );
                      }
                    }
                  }
                : null,
            trailing: entry.staffManaged && widget.assistedClinicId != null
                ? PopupMenuButton<String>(
                    enabled: !_busy,
                    tooltip: 'Non-app patient actions',
                    onSelected: (action) {
                      switch (action) {
                        case 'checkin':
                          _guestQueue(entry, false);
                        case 'cancel-checkin':
                          _guestQueue(entry, true);
                        case 'reschedule':
                          _reschedule(entry);
                        case 'cancel':
                          _cancel(entry);
                      }
                    },
                    itemBuilder: (context) => [
                      if (entry.status == 'booked')
                        const PopupMenuItem(
                          value: 'checkin',
                          child: Text('Check in non-app patient'),
                        ),
                      if (entry.status == 'checked_in')
                        const PopupMenuItem(
                          value: 'cancel-checkin',
                          child: Text('Cancel check-in'),
                        ),
                      if (entry.status == 'booked' &&
                          entry.start.isAfter(DateTime.now())) ...[
                        const PopupMenuItem(
                          value: 'reschedule',
                          child: Text('Reschedule'),
                        ),
                        const PopupMenuItem(
                          value: 'cancel',
                          child: Text('Cancel'),
                        ),
                      ],
                    ],
                  )
                : entry.status == 'booked' &&
                      entry.start.isAfter(DateTime.now())
                ? Wrap(
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => _reschedule(entry),
                        child: const Text('Reschedule'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _cancel(entry),
                        child: const Text('Cancel'),
                      ),
                    ],
                  )
                : null,
          ),
      ],
    );
  }
}

String _when(DateTime date) =>
    '${date.toLocal().year}-${date.toLocal().month.toString().padLeft(2, '0')}-${date.toLocal().day.toString().padLeft(2, '0')} ${date.toLocal().hour.toString().padLeft(2, '0')}:${date.toLocal().minute.toString().padLeft(2, '0')}';

class StaffSchedulePanel extends StatefulWidget {
  const StaffSchedulePanel({
    super.key,
    required this.repository,
    required this.clinicId,
    required this.providerId,
    required this.clinicName,
  });
  final AppointmentRepository repository;
  final String clinicId, providerId, clinicName;
  @override
  State<StaffSchedulePanel> createState() => _StaffSchedulePanelState();
}

class ClinicSchedulePanel extends StatefulWidget {
  const ClinicSchedulePanel({
    super.key,
    required this.repository,
    required this.clinicId,
    required this.clinicName,
  });
  final AppointmentRepository repository;
  final String clinicId, clinicName;
  @override
  State<ClinicSchedulePanel> createState() => _ClinicSchedulePanelState();
}

class _ClinicSchedulePanelState extends State<ClinicSchedulePanel> {
  List<DoctorListing>? _doctors;
  String? _providerId, _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doctors = await widget.repository.doctors(widget.clinicId);
      if (mounted) setState(() => _doctors = doctors);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Doctor listings are unavailable.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Clinic schedule · ${widget.clinicName}',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      if (_message != null) Text(_message!),
      if (_doctors == null && _message == null) const LinearProgressIndicator(),
      if (_doctors != null && _doctors!.isEmpty)
        const Text('No approved doctors are listed.'),
      if (_doctors != null && _doctors!.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: _providerId,
          decoration: const InputDecoration(labelText: 'Doctor'),
          items: [
            for (final doctor in _doctors!)
              DropdownMenuItem(value: doctor.id, child: Text(doctor.name)),
          ],
          onChanged: (id) => setState(() => _providerId = id),
        ),
      if (_providerId != null)
        StaffSchedulePanel(
          key: ValueKey(_providerId),
          repository: widget.repository,
          clinicId: widget.clinicId,
          providerId: _providerId!,
          clinicName: widget.clinicName,
        ),
    ],
  );
}

class _StaffSchedulePanelState extends State<StaffSchedulePanel> {
  ScheduleSettings? _schedule;
  List<AppointmentSlot>? _slots;
  DateTime? _day;
  TimeOfDay? _time;
  bool _busy = false;
  String? _message;
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
      final repository = widget.repository;
      if (repository is FirestoreAppointmentRepository) {
        _schedule = await ScheduleSettings.load(repository.db, widget.clinicId);
      }
      final slots = await widget.repository.staffSlots(
        widget.clinicId,
        widget.providerId,
      );
      if (mounted) setState(() => _slots = slots);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Schedule unavailable. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _create() async {
    if (_day == null || _time == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.repository.createSlot(
        widget.clinicId,
        widget.providerId,
        _schedule?.fromClinicTime(_day!, _time!.hour, _time!.minute) ??
            DateTime(
              _day!.year,
              _day!.month,
              _day!.day,
              _time!.hour,
              _time!.minute,
            ),
      );
      await _load();
      if (mounted) setState(() => _message = 'Time added.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Could not add this time. Choose a future start on the clinic duration grid, in its displayed timezone.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggle(AppointmentSlot slot) async {
    setState(() => _busy = true);
    try {
      await widget.repository.setUnavailable(slot, slot.status == 'available');
      await _load();
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not change this time.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Schedule · ${widget.clinicName}',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'Appointment times use this device’s local timezone unless a clinic timezone is explicitly shown.',
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Text(_message!),
      if (_schedule != null)
        Text(
          'Enter clinic-local time: ${_schedule!.timezone}. Each slot lasts ${_schedule!.minutes} minutes; start on that grid.',
        ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final day = await showDatePicker(
                      context: context,
                      firstDate: _schedule?.clinicNow() ?? DateTime.now(),
                      lastDate: (_schedule?.clinicNow() ?? DateTime.now()).add(
                        const Duration(days: 90),
                      ),
                      initialDate: _schedule?.clinicNow() ?? DateTime.now(),
                    );
                    if (mounted) setState(() => _day = day);
                  },
            child: Text(
              _day == null ? 'Choose date' : _when(_day!).split(' ').first,
            ),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(
                        _schedule?.clinicNow() ?? DateTime.now(),
                      ),
                    );
                    if (mounted) setState(() => _time = time);
                  },
            child: Text(_time == null ? 'Choose time' : _time!.format(context)),
          ),
          FilledButton(
            onPressed: _busy || _day == null || _time == null ? null : _create,
            child: const Text('Add available time'),
          ),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Refresh'),
          ),
        ],
      ),
      if (_slots != null && _slots!.isEmpty) const Text('No scheduled times.'),
      for (final slot in _slots ?? <AppointmentSlot>[])
        ListTile(
          title: Text(
            _schedule?.format(slot.start) ??
                '${_when(slot.start)} (device time)',
          ),
          subtitle: Text(slot.status),
          trailing:
              slot.status == 'booked' || !slot.start.isAfter(DateTime.now())
              ? null
              : TextButton(
                  onPressed: _busy ? null : () => _toggle(slot),
                  child: Text(
                    slot.status == 'available'
                        ? 'Mark unavailable'
                        : 'Make available',
                  ),
                ),
        ),
    ],
  );
}
