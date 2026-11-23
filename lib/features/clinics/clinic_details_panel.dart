import 'package:flutter/material.dart';

import 'clinic_repository.dart';
import 'queue_estimate_editor.dart';

class ClinicDetailsPanel extends StatefulWidget {
  const ClinicDetailsPanel({
    super.key,
    required this.repository,
    this.fixedClinicId,
    this.fixedClinicName,
  });
  final ClinicRepository repository;
  final String? fixedClinicId;
  final String? fixedClinicName;

  @override
  State<ClinicDetailsPanel> createState() => _ClinicDetailsPanelState();
}

class _ClinicDetailsPanelState extends State<ClinicDetailsPanel> {
  Future<List<ClinicDirectoryEntry>>? directory;
  Future<ClinicDetails?>? details;
  String? selectedId;
  bool busy = false;
  String? message;
  final name = TextEditingController();
  final category = TextEditingController();
  final location = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  final address = TextEditingController();
  final timezone = TextEditingController(text: 'Africa/Johannesburg');
  final hours = TextEditingController();
  final reason = TextEditingController();
  int slotMinutes = 30;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(ClinicDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fixedClinicId != widget.fixedClinicId ||
        oldWidget.repository != widget.repository) {
      _reload();
    }
  }

  void _reload() {
    if (widget.fixedClinicId case final id?) {
      selectedId = id;
      details = widget.repository.getClinic(id);
    } else {
      directory = widget.repository.listDirectory();
      if (selectedId case final id?) details = widget.repository.getClinic(id);
    }
  }

  @override
  void dispose() {
    for (final field in [
      name,
      category,
      location,
      phone,
      email,
      address,
      timezone,
      hours,
      reason,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  ClinicIdentity get _identity =>
      ClinicIdentity(name.text, category.text, location.text);
  ClinicSettings? get _settings {
    if (!['Africa/Johannesburg', 'UTC'].contains(timezone.text.trim()) ||
        name.text.trim().length < 2 ||
        category.text.trim().length < 2 ||
        location.text.trim().length < 2) {
      return null;
    }
    return ClinicSettings(
      phone.text,
      email.text,
      address.text,
      timezone.text,
      hours.text,
      slotMinutes,
    );
  }

  void _populate(ClinicDetails clinic) {
    name.text = clinic.name;
    category.text = clinic.category;
    location.text = clinic.location;
    phone.text = clinic.settings.phone;
    email.text = clinic.settings.email;
    address.text = clinic.settings.address;
    timezone.text = clinic.settings.timezone;
    hours.text = clinic.settings.operatingHours;
    slotMinutes = clinic.settings.slotMinutes;
  }

  Future<bool> _run(Future<void> Function() operation, String success) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await operation();
      if (!mounted) return false;
      setState(() {
        message = success;
        _reload();
      });
      return true;
    } catch (_) {
      if (!mounted) return false;
      setState(
        () => message = 'Change unavailable. Check your current access and entered details.',
      );
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create() async {
    final settings = _settings;
    if (settings == null) {
      setState(
        () => message =
            'Enter a name, category, location and supported timezone.',
      );
      return;
    }
    final created = await _run(
      () => widget.repository.createClinic(ClinicDraft(_identity, settings)),
      '${name.text.trim()} was created.',
    );
    if (created) {
      name.clear();
      category.clear();
      location.clear();
      phone.clear();
      email.clear();
      address.clear();
      hours.clear();
    }
  }

  Future<void> _saveSettings(String id) async {
    final settings = _settings;
    if (settings == null) {
      setState(() => message = 'Check the clinic settings before saving.');
      return;
    }
    await _run(
      () => widget.repository.updateSettings(id, settings),
      'Clinic settings saved.',
    );
  }

  Future<void> _archive(String id, String clinicName) async {
    if (reason.text.trim().length < 10) {
      setState(
        () => message = 'Enter an archive reason of at least 10 characters.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive $clinicName?'),
        content: const Text(
          'This keeps the clinic history and removes its public directory entry from active browsing. Existing staff access stops.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive clinic'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final archived = await _run(
      () => widget.repository.archiveClinic(id, reason.text),
      '$clinicName was archived.',
    );
    if (archived && mounted) {
      setState(() {
        selectedId = null;
        details = null;
      });
      name.clear();
      category.clear();
      location.clear();
      phone.clear();
      email.clear();
      address.clear();
      hours.clear();
      reason.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = widget.fixedClinicId == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          platform ? 'Clinic management' : 'Clinic details',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        Text(
          platform
              ? 'Create a clinic or select one by name to manage its settings. Active clinics appear below.'
              : 'Manage permitted settings for ${widget.fixedClinicName ?? 'this clinic'}.',
        ),
        if (platform) ...[
          const SizedBox(height: 16),
          FutureBuilder<List<ClinicDirectoryEntry>>(
            future: directory,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Text(
                  snapshot.hasError
                      ? 'Clinic directory unavailable.'
                      : 'Loading clinics…',
                );
              }
              final entries = snapshot.data!;
              if (entries.isEmpty) {
                return const Text('No active clinics found.');
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active clinics',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final entry in entries)
                    ListTile(
                      title: Text(entry.name),
                      subtitle: Text('${entry.category} · ${entry.location}'),
                      selected: selectedId == entry.id,
                      onTap: () => setState(() {
                        selectedId = entry.id;
                        name.clear();
                        details = widget.repository.getClinic(entry.id);
                      }),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 32),
        ],
        if (details != null)
          FutureBuilder<ClinicDetails?>(
            future: details,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Text(
                  snapshot.hasError
                      ? 'Clinic details unavailable for your access.'
                      : 'Loading settings…',
                );
              }
              final clinic = snapshot.data!;
              if (name.text.isEmpty ||
                  name.text != clinic.name && !busy && message != null) {
                _populate(clinic);
              }
              return _form(clinic);
            },
          ),
        if (platform && selectedId == null) ...[
          Text('Create clinic', style: Theme.of(context).textTheme.titleLarge),
          _form(null),
        ],
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(message!),
          ),
      ],
    );
  }

  Widget _form(ClinicDetails? clinic) {
    final platform = widget.fixedClinicId == null;
    final active = clinic == null || clinic.status == 'active';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (clinic != null)
          Text(clinic.name, style: Theme.of(context).textTheme.titleLarge),
        if (clinic != null) Text('Status: ${clinic.status}'),
        if (platform || clinic == null) ...[
          _field(name, 'Clinic display name'),
          _field(category, 'Clinic category'),
          _field(location, 'Public location'),
        ] else ...[
          Text('Category: ${clinic.category}'),
          Text('Location: ${clinic.location}'),
        ],
        _field(phone, 'Contact phone'),
        _field(email, 'Contact email'),
        _field(address, 'Private address'),
        DropdownButtonFormField<String>(
          isExpanded: true,
          key: ValueKey('timezone-${clinic?.clinicId}'),
          initialValue: ['Africa/Johannesburg', 'UTC'].contains(timezone.text)
              ? timezone.text
              : null,
          decoration: const InputDecoration(labelText: 'Clinic timezone'),
          items: const [
            DropdownMenuItem(
              value: 'Africa/Johannesburg',
              child: Text('Africa/Johannesburg (UTC+02:00)'),
            ),
            DropdownMenuItem(value: 'UTC', child: Text('UTC')),
          ],
          onChanged: busy || clinic != null
              ? null
              : (value) => setState(() => timezone.text = value!),
        ),
        const Text(
          'Timezone and duration are chosen at creation and then locked to preserve reservation grids and existing queue days. UTC and Africa/Johannesburg are supported; DST zones require a separately reviewed service-day design.',
        ),
        _field(hours, 'Operating hours (display only)'),
        DropdownButtonFormField<int>(
          isExpanded: true,
          key: ValueKey('duration-${clinic?.clinicId}'),
          initialValue: slotMinutes,
          decoration: const InputDecoration(labelText: 'Appointment duration'),
          items: [
            for (final minutes in [15, 20, 30, 60])
              DropdownMenuItem(value: minutes, child: Text('$minutes minutes')),
          ],
          onChanged: busy || clinic != null
              ? null
              : (value) => setState(() => slotMinutes = value!),
        ),
        if (clinic != null && widget.repository is FirestoreClinicRepository)
          QueueEstimateEditor(
            key: ValueKey(clinic.clinicId),
            repository: widget.repository as FirestoreClinicRepository,
            clinicId: clinic.clinicId,
          ),
        const SizedBox(height: 12),
        if (clinic == null)
          FilledButton(
            onPressed: busy ? null : _create,
            child: const Text('Create clinic'),
          ),
        if (clinic != null && active) ...[
          if (widget.repository is ClinicQueueSetup)
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => _run(
                      () => (widget.repository as ClinicQueueSetup).setupQueue(
                        clinic.clinicId,
                      ),
                      'Queue configuration is ready. Existing queue settings are preserved.',
                    ),
              child: const Text('Set up clinic queue'),
            ),
          FilledButton(
            onPressed: busy ? null : () => _saveSettings(clinic.clinicId),
            child: const Text('Save settings'),
          ),
          if (platform) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => _run(
                      () => widget.repository.updateIdentity(
                        clinic.clinicId,
                        _identity,
                      ),
                      'Clinic directory details saved.',
                    ),
              child: const Text('Save public details'),
            ),
            _field(reason, 'Reason for archiving'),
            TextButton(
              onPressed: busy
                  ? null
                  : () => _archive(clinic.clinicId, clinic.name),
              child: const Text('Archive clinic'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    ),
  );
}
