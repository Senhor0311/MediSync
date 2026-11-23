import '../../shared/data/history_page.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'record_repository.dart';
import 'record_support.dart';
import 'record_export.dart';

import 'dart:async';
import 'dart:math';

import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';
import '../auth/inactivity_session.dart';

class RecordPatientChoice {
  const RecordPatientChoice(
    this.id,
    this.label, {
    required this.encounterType,
    required this.encounterId,
    this.visitAt,
  });
  final String id, label, encounterType, encounterId;
  final DateTime? visitAt;
  String get key => '$encounterType-$encounterId';
}

class RecordsPanel extends StatefulWidget {
  const RecordsPanel({
    super.key,
    required this.repository,
    required this.patientMode,
    required this.patientId,
    this.clinicId,
    this.clinicLabel,
    this.loadPatientChoices,
    this.loadMorePatientChoices,
    this.hasMorePatientChoices,
  });
  final RecordRepository repository;
  final bool patientMode;
  final String patientId;
  final String? clinicId, clinicLabel;
  final Future<List<RecordPatientChoice>> Function()? loadPatientChoices;
  final Future<List<RecordPatientChoice>> Function()? loadMorePatientChoices;
  final bool Function()? hasMorePatientChoices;

  @override
  State<RecordsPanel> createState() => _RecordsPanelState();
}

class _RecordsPanelState extends State<RecordsPanel> {
  int _generation = 0;
  bool _history = false;
  bool _needsReconnect = false;
  Future<void> _recoverReads() async {
    final repository = widget.repository;
    if (_needsReconnect && repository is RecordReadRecovery) {
      await (repository as RecordReadRecovery).reconnectReads();
      _needsReconnect = false;
    }
  }

  final _current = <String, RecordSummary>{};
  final _attributions = <String, Map<String, String>>{};
  final _unavailable = <String, String>{};
  String _clinic(RecordSummary r) => _attributions[r.id]?['clinic'] != null
      ? '${_attributions[r.id]!['clinic']} (verified record attribution)'
      : _clinics[r.clinicId] ?? 'Clinic name unavailable';
  String _provider(RecordSummary r) => _attributions[r.id]?['provider'] != null
      ? '${_attributions[r.id]!['provider']} (verified record attribution)'
      : _providers[r.authorId] ?? 'Provider name unavailable';
  String _clinicFilter = '', _providerFilter = '', _typeFilter = '';
  DateTime? _from, _until;
  Timer? _recheck;
  void _locked() {
    if (ClinicalCrypto.instance?.unlocked == false && mounted) {
      _generation++;
      setState(() {
        _records = null;
        _detail = null;
        _current.clear();
        _attributions.clear();
        _unavailable.clear();
        _clinics.clear();
        _providers.clear();
        _choices = null;
        _encounter = null;
        _patient.clear();
      });
    }
  }

  final _patient = TextEditingController();
  List<RecordSummary>? _records;
  String? _next;
  final _clinics = <String, String>{};
  final _providers = <String, String>{};
  MedicalRecord? _detail;
  String? _selectedId, _message;
  bool _busy = false;
  List<RecordPatientChoice>? _choices;
  RecordPatientChoice? _encounter;

  @override
  void initState() {
    super.initState();
    ClinicalCrypto.instance?.addListener(_locked);
    _recheck = Timer.periodic(const Duration(seconds: 30), (_) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      if (_detail != null && !_busy) _open(_detail!.summary);
    });
    _patient.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.patientMode) _load();
    if (!widget.patientMode && widget.loadPatientChoices != null) {
      _loadChoices();
    }
  }

  @override
  void didUpdateWidget(RecordsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId ||
        oldWidget.clinicId != widget.clinicId ||
        oldWidget.patientMode != widget.patientMode) {
      _generation++;
      _records = null;
      _detail = null;
      _selectedId = null;
      _next = null;
      _choices = null;
      _encounter = null;
      _patient.clear();
      _current.clear();
      _attributions.clear();
      _clinics.clear();
      _providers.clear();
      _clinicFilter = '';
      _providerFilter = '';
      _typeFilter = '';
      if (widget.patientMode) {
        _load();
      } else if (widget.loadPatientChoices != null) {
        _loadChoices();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _recheck?.cancel();
    ClinicalCrypto.instance?.removeListener(_locked);
    _patient.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false, bool replaceLoaded = false}) async {
    if (_busy) return;
    final generation = ++_generation;
    final patientId = widget.patientMode
        ? widget.patientId
        : _patient.text.trim();
    if (patientId.isEmpty || (!widget.patientMode && _encounter == null)) {
      setState(() => _message = 'Choose a synthetic encounter.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      if (!more) {
        _records = null;
        _current.clear();
        _attributions.clear();
        _unavailable.clear();
        _next = null;
      }
      _detail = null;
      _selectedId = null;
      if (!more) {
        _clinics.clear();
        _providers.clear();
      }
    });
    var readStage = 'record history';
    try {
      final repository = widget.repository;
      await _recoverReads();
      final HistoryPage<RecordSummary>? page =
          repository is HistoryPager<RecordSummary>
          ? await (repository as HistoryPager<RecordSummary>).historyPage(
              after: more ? _next : null,
              scope: {
                'patientId': patientId,
                if (!widget.patientMode) ...{
                  'clinicId': widget.clinicId!,
                  'encounterType': _encounter!.encounterType,
                  'encounterId': _encounter!.encounterId,
                },
              },
            )
          : null;
      final records =
          page?.items ??
          (widget.patientMode
              ? await widget.repository.listPatient(patientId)
              : await widget.repository.listPractitioner(
                  widget.clinicId!,
                  patientId,
                  encounterType: _encounter!.encounterType,
                  encounterId: _encounter!.encounterId,
                ));
      final clinics = <String, String>{if (!replaceLoaded) ..._clinics};
      final providers = <String, String>{if (!replaceLoaded) ..._providers};
      final currents = <String, RecordSummary>{if (!replaceLoaded) ..._current};
      final attributions = <String, Map<String, String>>{
        if (!replaceLoaded) ..._attributions,
      };
      final unavailable = <String, String>{...?page?.unavailable};
      for (final record in records) {
        if (repository is RecordVersions) {
          try {
            readStage = 'current version';
            currents[record.root] ??= await (repository as RecordVersions)
                .currentVersion(record);
            // Immutable verified snapshots retain attribution after unpublication.
            readStage = 'historical attribution';
            final names = await (repository as RecordVersions).attribution(
              record,
            );
            attributions[record.id] = names;
            final current = currents[record.root]!;
            if (current.id != record.id &&
                !attributions.containsKey(current.id)) {
              attributions[current.id] = await (repository as RecordVersions)
                  .attribution(current);
            }
          } catch (error) {
            if (_denied(error)) rethrow;
            unavailable[record.id] = 'Version status or attribution unavailable. Refresh to retry; the original remains listed.';
          }
        }
        if (!clinics.containsKey(record.clinicId)) {
          try {
            clinics[record.clinicId] =
                await widget.repository.clinicName(record.clinicId) ??
                'Clinic name unavailable';
          } catch (_) {
            clinics[record.clinicId] = 'Clinic name unavailable';
          }
        }
        if (!providers.containsKey(record.authorId)) {
          try {
            providers[record.authorId] =
                await widget.repository.providerName(record.authorId) ??
                'Provider name unavailable';
          } catch (_) {
            providers[record.authorId] = 'Provider name unavailable';
          }
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _records =
            {
              for (final row in [
                ...?(more && !replaceLoaded ? _records : null),
                ...records,
              ])
                row.id: row,
            }.values.toList()..sort((a, b) {
              final date = b.visitAt.compareTo(a.visitAt);
              return date != 0 ? date : b.id.compareTo(a.id);
            });
        _next = page?.next;
        if (replaceLoaded) {
          _clinics.clear();
          _providers.clear();
          _current.clear();
          _attributions.clear();
          _unavailable.clear();
        }
        _clinics.addAll(clinics);
        _providers.addAll(providers);
        _current.addAll(currents);
        _attributions.addAll(attributions);
        _unavailable.addAll(unavailable);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _message = '${_safeMessage(error)} Refresh $readStage to try again.';
        if (_denied(error)) {
          _needsReconnect = true;
          _records = null;
          _current.clear();
          _attributions.clear();
          _detail = null;
        }
      });
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _loadChoices({bool more = false}) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final page = await (more
          ? widget.loadMorePatientChoices!()
          : widget.loadPatientChoices!());
      final choices = {
        for (final c in [...?(more ? _choices : null), ...page]) c.key: c,
      }.values.toList();
      if (mounted && generation == _generation) {
        setState(() {
          _choices = choices;
          final selected = choices
              .where((c) => c.key == _encounter?.key)
              .firstOrNull;
          if (selected == null) {
            _encounter = null;
            _patient.clear();
            _records = null;
            _detail = null;
          }
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _message = 'Authorised encounters could not be loaded. Reconnect and retry. Ask the patient to approve or renew the exact encounter if access expired.';
          if (_denied(error)) {
            _needsReconnect = true;
            _detail = null;
            _records = null;
            _choices = null;
            _encounter = null;
          }
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _open(RecordSummary summary) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _message = null;
      _detail = null;
      _selectedId = summary.id;
    });
    try {
      final detail = await widget.repository.getRecord(summary.id);
      final current = widget.repository is RecordVersions
          ? await (widget.repository as RecordVersions).currentVersion(summary)
          : summary;
      if (!mounted || generation != _generation || _selectedId != summary.id) {
        return;
      }
      if (detail.summary.patientId != summary.patientId ||
          detail.summary.clinicId != summary.clinicId) {
        throw const FormatException('Record mismatch');
      }
      setState(() {
        _detail = detail;
        _current[summary.root] = current;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _message = _safeMessage(error);
          if (_denied(error)) {
            _needsReconnect = true;
            _records = null;
            _current.clear();
            _attributions.clear();
          }
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _create({MedicalRecord? correcting}) async {
    final generation = _generation;
    final scope = ClinicalReadScope();
    if (correcting != null) {
      setState(() {
        _busy = true;
        _message = null;
      });
      try {
        final fresh = await widget.repository.getRecord(correcting.summary.id);
        if (fresh.summary.authorId != widget.patientId) {
          throw const RecordFailure(
            'Only the original author may append a correction.',
          );
        }
        if (widget.repository is RecordVersions) {
          final current = await (widget.repository as RecordVersions)
              .currentVersion(fresh.summary);
          if (current.id != fresh.summary.id) {
            if (mounted) {
              setState(() {
                _current[current.root] = current;
                _message = 'A newer correction exists. Open the current version before appending another correction.';
              });
            }
            return;
          }
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _message = _safeMessage(error);
            if (_denied(error)) {
              _needsReconnect = true;
              _records = null;
              _detail = null;
              _current.clear();
              _attributions.clear();
            }
          });
        }
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted || generation != _generation || !scope.active) return;
    final saved = await showClinicalDialog<bool>(
      context: context,
      isActive: () => generation == _generation && scope.active,
      authorised: correcting != null && widget.repository is RecordAuthority
          ? () => (widget.repository as RecordAuthority).stillAuthorised(
              correcting.summary,
            )
          : null,
      barrierDismissible: false,
      builder: (context) => _CreateDialog(
        clinicId: widget.clinicId!,
        patientId: _patient.text.trim(),
        encounterType: _encounter!.encounterType,
        encounterId: _encounter!.encounterId,
        clinicName: widget.clinicLabel ?? 'Clinic',
        previous: correcting,
        identity: _encounter!.label,
        save: (draft, previous) async {
          await _recoverReads();
          if (previous == null) {
            await widget.repository.createFinal(draft);
          } else {
            await (widget.repository as RecordCorrections).correct(
              previous,
              draft,
            );
          }
        },
        latest: correcting != null && widget.repository is RecordVersions
            ? () async {
                await _recoverReads();
                final current = await (widget.repository as RecordVersions)
                    .currentVersion(correcting.summary);
                return widget.repository.getRecord(current.id);
              }
            : null,
        accessLost: () {
          _needsReconnect = true;
          if (mounted) {
            setState(() {
              _records = null;
              _detail = null;
              _current.clear();
              _attributions.clear();
            });
          }
        },
      ),
    );
    if (saved == true && mounted) await _load();
  }

  List<RecordSummary> get _shown {
    final rows = _history
        ? [...?_records]
        : <RecordSummary>{
            for (final row in _records ?? <RecordSummary>[])
              _current[row.root] ?? row,
          }.toList();
    return rows
        .where(
          (r) =>
              (_clinicFilter.isEmpty || r.clinicId == _clinicFilter) &&
              (_providerFilter.isEmpty || r.authorId == _providerFilter) &&
              (_typeFilter.isEmpty || r.type == _typeFilter) &&
              (_from == null || !r.visitAt.isBefore(_from!)) &&
              (_until == null ||
                  r.visitAt.isBefore(_until!.add(const Duration(days: 1)))),
        )
        .toList()
      ..sort((a, b) {
        final date = b.visitAt.compareTo(a.visitAt);
        return date != 0 ? date : b.id.compareTo(a.id);
      });
  }

  Widget _filters() => ExpansionTile(
    key: PageStorageKey(
      'record-filters-${widget.patientId}-${widget.clinicId}-${_encounter?.key ?? 'own'}',
    ),
    title: const Text('Filter loaded records'),
    children: [
      const Text(
        'Filters apply only to loaded pages and their current versions. Load more or refresh to search further within your authorised history.',
      ),
      for (final kind in ['Clinic', 'Provider', 'Record type'])
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: '',
          decoration: InputDecoration(labelText: kind),
          items: [
            const DropdownMenuItem(value: '', child: Text('All')),
            if (kind == 'Clinic')
              for (final id
                  in (_records ?? <RecordSummary>[])
                      .map((r) => r.clinicId)
                      .toSet())
                DropdownMenuItem(
                  value: id,
                  child: Text(_clinics[id] ?? 'Unavailable clinic'),
                ),
            if (kind == 'Provider')
              for (final id
                  in (_records ?? <RecordSummary>[])
                      .map((r) => r.authorId)
                      .toSet())
                DropdownMenuItem(
                  value: id,
                  child: Text(_providers[id] ?? 'Unavailable provider'),
                ),
            if (kind == 'Record type') ...const [
              DropdownMenuItem(value: 'visit', child: Text('Visit')),
              DropdownMenuItem(value: 'follow_up', child: Text('Follow-up')),
            ],
          ],
          onChanged: (v) => setState(() {
            if (kind == 'Clinic') {
              _clinicFilter = v!;
            } else if (kind == 'Provider') {
              _providerFilter = v!;
            } else {
              _typeFilter = v!;
            }
          }),
        ),
      Wrap(
        children: [
          for (final start in [true, false])
            TextButton(
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  firstDate: DateTime(1900),
                  lastDate: DateTime(2200),
                  initialDate: DateTime.now(),
                );
                if (mounted && date != null) {
                  setState(() {
                    if (start) {
                      _from = date;
                    } else {
                      _until = date;
                    }
                  });
                }
              },
              child: Text(
                start
                    ? 'From: ${_from == null ? 'any date' : _date(_from!)}'
                    : 'To: ${_until == null ? 'any date' : _date(_until!)}',
              ),
            ),
          TextButton(
            onPressed: () => setState(() {
              _from = null;
              _until = null;
            }),
            child: const Text('Clear dates'),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Patient records', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 8),
      const Text(
        'Synthetic-data research prototype. Do not enter real patient information.',
      ),
      if (!widget.patientMode) ...[
        const SizedBox(height: 20),
        Text('Clinic: ${widget.clinicLabel ?? 'Clinic name unavailable'}'),
        const SizedBox(height: 12),
        if (widget.loadPatientChoices != null) ...[
          if (_choices == null && !_busy)
            TextButton(
              onPressed: _loadChoices,
              child: const Text('Retry encounters'),
            ),
          if (_choices != null && _choices!.isEmpty)
            const Text(
              'No eligible encounters. Ask the patient to approve or reapprove the exact encounter in Care permissions. Accepted referrals grant only their bounded follow-up context.',
            ),
          if (_choices != null && _choices!.isNotEmpty)
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: _encounter?.key,
              decoration: const InputDecoration(labelText: 'Patient encounter'),
              items: [
                for (final choice in _choices!)
                  DropdownMenuItem(
                    value: choice.key,
                    child: Text(
                      choice.label,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (id) {
                      _encounter = _choices!.firstWhere(
                        (choice) => choice.key == id,
                      );
                      _patient.text = _encounter!.id;
                      _load();
                    },
            ),
          const Text(
            'Encounter selection does not grant clinical access. Firestore checks current membership and exact encounter authorization. Historical records require separate approval.',
          ),
        ] else
          const Text(
            'Encounter selection is unavailable. Records remain closed until an authorized encounter is supplied.',
          ),
        Wrap(
          spacing: 12,
          children: [
            if (widget.loadPatientChoices != null)
              TextButton(
                onPressed: _busy ? null : _loadChoices,
                child: const Text('Refresh encounters'),
              ),
            if (widget.loadMorePatientChoices != null &&
                widget.hasMorePatientChoices?.call() == true)
              TextButton(
                onPressed: _busy ? null : () => _loadChoices(more: true),
                child: const Text('Load older encounters'),
              ),
            FilledButton(
              onPressed: _busy || _encounter == null ? null : _load,
              child: const Text('Find records'),
            ),
            FilledButton.tonal(
              onPressed: _busy || _encounter == null ? null : _create,
              child: const Text('Create final record'),
            ),
          ],
        ),
      ],
      if (_encounter != null) Text('Selected: ${_encounter!.label}'),
      if (widget.patientMode)
        TextButton.icon(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh history'),
        ),
      if (widget.patientMode &&
          widget.repository is HistoryPager<RecordSummary>)
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => showClinicalDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => MedicalExportDialog(
                    export: MedicalExport(widget.repository, widget.patientId),
                  ),
                ),
          icon: const Icon(Icons.print),
          label: const Text('Readable medical-record export'),
        ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            _message!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      for (final entry in _unavailable.entries)
        Text('Unavailable record ${entry.key}: ${entry.value}'),
      if (_records != null && !_busy) ...[
        _filters(),
        SwitchListTile(
          title: const Text('Show previous versions'),
          subtitle: const Text(
            'Latest versions shown by default. History retains immutable versions and correction reasons.',
          ),
          value: _history,
          onChanged: (v) => setState(() => _history = v),
        ),
        const SizedBox(height: 24),
        if (_records!.isEmpty) const Text('No visible records found.'),
        if (_records!.isNotEmpty && _shown.isEmpty)
          const Text(
            'No loaded records match these filters. Change the filters or load more authorised history.',
          ),
        if ((_records?.length ?? 0) >= 500)
          const Text(
            '500 versions loaded. Continue to older history to release these loaded rows; Refresh returns to the newest page. Failed continuation retains this page and cursor.',
          ),
        if (_next != null)
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _load(
                    more: true,
                    replaceLoaded: (_records?.length ?? 0) >= 500,
                  ),
            child: Text(
              (_records?.length ?? 0) >= 500
                  ? 'Continue older history (release loaded rows)'
                  : 'Load more records',
            ),
          ),
        for (final record in _shown)
          Card(
            child: ListTile(
              title: Text(
                record.type == 'follow_up'
                    ? 'Follow-up record'
                    : 'Visit record',
              ),
              subtitle: Text(
                '${recordDate(record.visitAt)} · revision ${record.revision} · ${_current[record.root] == null
                    ? 'Current status unavailable'
                    : _current[record.root]!.id != record.id
                    ? 'Historical version; newer correction available'
                    : 'Current version'} · ${_clinic(record)} · ${_provider(record)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(record),
            ),
          ),
      ],
      if (_detail != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Final record · revision ${_detail!.summary.revision}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  'Visit: ${recordDate(_detail!.summary.visitAt)}${_detail!.summary.dateSource == null || _detail!.summary.dateSource == 'legacy-preserved' ? ' · historical recorded date; encounter provenance unverified' : ''}',
                ),
                Text(
                  '${_detail!.summary.revision > 1 ? 'Amendment created' : 'Record created'}: ${recordDate(_detail!.summary.createdAt)}',
                ),
                if (_current[_detail!.summary.root]?.id != null &&
                    _current[_detail!.summary.root]!.id != _detail!.summary.id)
                  TextButton(
                    onPressed: () => _open(_current[_detail!.summary.root]!),
                    child: const Text('Open newer correction'),
                  ),
                Text(
                  '${_date(_detail!.summary.visitAt)} · ${_clinic(_detail!.summary)}',
                ),
                Text('Provider: ${_provider(_detail!.summary)}'),
                const SizedBox(height: 12),
                if (_detail!.content['legacyPlaintext'] == true)
                  const Text(
                    'Legacy plaintext record — application encryption has not been applied to this historical content.',
                  ),
                _contentLine('Notes', _detail!.content['notes']),
                if (_detail!.summary.supersedesId != null)
                  const Text(
                    'Append-only correction of the preceding version.',
                  ),
                if (_detail!.content['correctionReason'] != null)
                  _contentLine(
                    'Correction reason',
                    _detail!.content['correctionReason'],
                  ),
                if (!widget.patientMode &&
                    _detail!.summary.authorId == widget.patientId &&
                    (_current[_detail!.summary.root]?.id ??
                            _detail!.summary.id) ==
                        _detail!.summary.id &&
                    widget.repository is RecordCorrections)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _create(correcting: _detail),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Append correction'),
                  ),
                if (!widget.patientMode && _detail!.internalNotes != null)
                  _contentLine(
                    'Internal practitioner notes · author only',
                    _detail!.internalNotes,
                  ),
                for (final field in const [
                  ('Diagnoses', 'diagnoses'),
                  ('Prescriptions', 'prescriptions'),
                  ('Medications', 'medications'),
                  ('Lab result metadata', 'labResultMetadata'),
                ])
                  _contentLine(
                    field.$1,
                    _detail!.content[field.$2] is List
                        ? (_detail!.content[field.$2] as List).join(', ')
                        : '',
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}

Widget _contentLine(String label, Object? value) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Text(
    '$label: ${value is String && value.isNotEmpty ? value : 'None'}',
  ),
);
String _date(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _safeMessage(Object error) =>
    error is FirebaseException && error.code == 'permission-denied'
    ? 'Access to these records is unavailable.'
    : error is ClinicalCryptoFailure
    ? error.message
    : error is RecordFailure
    ? error.message
    : error is FormatException || error is TypeError
    ? 'This historical version has unusable metadata or content. Other records remain available. Request reviewed access; no clinical information has been repaired or invented.'
    : error is FirebaseException &&
          ['unavailable', 'deadline-exceeded'].contains(error.code)
    ? 'Connection unavailable. Your draft is retained in this editor. Reconnect and retry.'
    : error is FirebaseException && error.code == 'failed-precondition'
    ? 'This operation is not ready. Refresh the encounter and record history, then retry. If it persists, ask support to check application setup.'
    : 'Records could not be loaded or saved. Please try again.';
bool _denied(Object error) =>
    error is FirebaseException && error.code == 'permission-denied';

class _CreateDialog extends StatefulWidget {
  const _CreateDialog({
    required this.clinicId,
    required this.patientId,
    required this.clinicName,
    required this.encounterType,
    required this.encounterId,
    required this.identity,
    required this.save,
    required this.accessLost,
    this.latest,
    this.previous,
  });
  final String clinicId, patientId, clinicName, encounterType, encounterId;
  final MedicalRecord? previous;
  final String identity;
  final Future<void> Function(RecordDraft, RecordSummary?) save;
  final Future<MedicalRecord> Function()? latest;
  final VoidCallback accessLost;
  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _form = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final _internalNotes = TextEditingController();
  final _diagnosis = TextEditingController();
  final _prescription = TextEditingController();
  final _medication = TextEditingController();
  final _lab = TextEditingController();
  final _correction = TextEditingController();
  String _type = 'visit';
  bool _visible = true;
  bool _saving = false, _attempted = false, _confirmed = false;
  String? _error;
  MedicalRecord? _base, _review;
  // Reused across uncertain acknowledgements. Plaintext never leaves memory.
  final _operation = List.generate(
    24,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)],
  ).join();
  void _locked() {
    if (ClinicalCrypto.instance?.unlocked == false && mounted) {
      _base = null;
      _review = null;
      for (final c in [
        _notes,
        _internalNotes,
        _diagnosis,
        _prescription,
        _medication,
        _lab,
        _correction,
      ]) {
        c.clear();
      }
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    ClinicalCrypto.instance?.addListener(_locked);
    final previous = widget.previous;
    _base = previous;
    if (previous != null) {
      _type = previous.summary.type;
      _visible = previous.summary.patientVisible;
      _notes.text = previous.content['notes'] as String? ?? '';
      _internalNotes.text = previous.internalNotes ?? '';
      for (final field in [
        ('diagnoses', _diagnosis),
        ('prescriptions', _prescription),
        ('medications', _medication),
        ('labResultMetadata', _lab),
      ]) {
        field.$2.text = (previous.content[field.$1] as List? ?? []).join(', ');
      }
    }
  }

  @override
  void dispose() {
    ClinicalCrypto.instance?.removeListener(_locked);
    _base = null;
    _review = null;
    for (final controller in [
      _notes,
      _internalNotes,
      _diagnosis,
      _prescription,
      _medication,
      _lab,
      _correction,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(
        widget.previous == null
            ? 'Create immutable final record'
            : 'Append immutable correction',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Selected: ${widget.identity} · ${widget.clinicName}'),
                const Text(
                  'Final records cannot be edited or deleted. Use fictional content only.',
                ),
                const Text(
                  'Patient-visible consultation fields may be read and explicitly shared by the patient. Internal notes use a separate author-only encrypted document and are never shared or included in patient exports.',
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_saving && _confirmed) const LinearProgressIndicator(),
                if (_attempted)
                  const Text(
                    'This save has a stable identifier. Retry to confirm the same version. Fields are held unchanged until the outcome is resolved. Closing does not cancel a possible server save; check history before starting another record.',
                  ),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(value: 'visit', child: Text('Visit')),
                    DropdownMenuItem(
                      value: 'follow_up',
                      child: Text('Follow-up'),
                    ),
                  ],
                  onChanged: widget.previous != null || _attempted
                      ? null
                      : (value) => setState(() {
                          _type = value!;
                          _confirmed = false;
                        }),
                ),
                if (_error != null && widget.latest != null)
                  TextButton(
                    onPressed: _saving || _attempted
                        ? null
                        : () async {
                            setState(() => _saving = true);
                            try {
                              final current = await widget.latest!();
                              if (mounted) {
                                setState(() {
                                  _base = current;
                                  _review = current;
                                  _attempted = false;
                                  _error = null;
                                  _confirmed = false;
                                });
                              }
                            } catch (e) {
                              if (_denied(e)) widget.accessLost();
                              if (mounted) {
                                setState(() => _error = _safeMessage(e));
                              }
                            } finally {
                              if (mounted) setState(() => _saving = false);
                            }
                          },
                    child: const Text(
                      'Review latest version; keep proposed text',
                    ),
                  ),
                if (_review != null)
                  ExpansionTile(
                    key: PageStorageKey(
                      'record-correction-review-${_review!.summary.id}',
                    ),
                    title: Text(
                      'Review current revision ${_review!.summary.revision} before finalising your retained proposal',
                    ),
                    children: [
                      if (_review!.internalNotes != null)
                        Text(
                          'Current author-only internal note: ${_review!.internalNotes}',
                        ),
                      for (final field in [
                        'notes',
                        'diagnoses',
                        'prescriptions',
                        'medications',
                        'labResultMetadata',
                        'correctionReason',
                      ])
                        if (_review!.content[field] != null)
                          Text('$field: ${_review!.content[field]}'),
                    ],
                  ),
                SwitchListTile(
                  title: const Text('Visible to patient'),
                  value: _visible,
                  onChanged: widget.previous != null || _attempted
                      ? null
                      : (value) => setState(() {
                          _visible = value;
                          _confirmed = false;
                        }),
                ),
                _field(_notes, 'Fictional notes', 5000),
                _field(
                  _internalNotes,
                  'Internal fictional notes (author only)',
                  5000,
                ),
                _field(_diagnosis, 'Fictional diagnosis (optional)', 2000),
                _field(
                  _prescription,
                  'Fictional prescription (optional)',
                  2000,
                ),
                _field(_medication, 'Fictional medication (optional)', 2000),
                _field(
                  _lab,
                  'Fictional written laboratory results (optional)',
                  2000,
                ),
                if (widget.previous != null)
                  _field(_correction, 'Correction reason (required)', 200),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  if (!_form.currentState!.validate()) return;
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  try {
                    if (!_confirmed) {
                      final confirmed = await showClinicalDialog<bool>(
                        context: context,
                        builder: (confirmation) => AlertDialog(
                          title: Text(
                            widget.previous == null
                                ? 'Confirm final medical record'
                                : 'Confirm append-only correction',
                          ),
                          content: SingleChildScrollView(
                            child: Text(
                              'Selected: ${widget.identity}\nClinic: ${widget.clinicName}\n${_visible ? 'Consultation fields are visible to the patient.' : 'Consultation fields are not visible to the patient.'}\nInternal notes remain in a separate author-only encrypted document. Final records are immutable.${_base == null ? '' : '\nCorrecting current revision ${_base!.summary.revision}; the original visit date is preserved.'}',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(confirmation, false),
                              child: const Text('Review form'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(confirmation, true),
                              child: Text(
                                widget.previous == null
                                    ? 'Confirm final record'
                                    : 'Confirm correction',
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !mounted) return;
                      _confirmed = true;
                    }
                    await widget.save(
                      RecordDraft(
                        operationId: _operation,
                        clinicId: widget.clinicId,
                        patientId: widget.patientId,
                        encounterType: widget.encounterType,
                        encounterId: widget.encounterId,
                        type: _type,
                        patientVisible: _visible,
                        notes: _notes.text,
                        internalNotes: _internalNotes.text,
                        diagnosis: _diagnosis.text,
                        prescription: _prescription.text,
                        medication: _medication.text,
                        labResult: _lab.text,
                        correctionReason: _correction.text,
                        preservedItems: {
                          for (final field in [
                            ('diagnoses', _diagnosis),
                            ('prescriptions', _prescription),
                            ('medications', _medication),
                            ('labResultMetadata', _lab),
                          ])
                            if (widget.previous?.content[field.$1] is List &&
                                (widget.previous!.content[field.$1] as List)
                                        .join(', ') ==
                                    field.$2.text)
                              field.$1: List<String>.from(
                                widget.previous!.content[field.$1] as List,
                              ),
                        },
                      ),
                      _base?.summary,
                    );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (error) {
                    if (_denied(error)) widget.accessLost();
                    if (mounted) {
                      setState(() {
                        // Definite rejection permits editing. Network/unknown outcomes keep
                        // the exact submitted form so an eventual commit cannot be mistaken
                        // for different content on a retry.
                        _attempted =
                            error is RecordFailure && error.operationRejected
                            ? false
                            : _attempted ||
                                  !(error is RecordFailure ||
                                      error is ClinicalCryptoFailure ||
                                      _denied(error));
                        _error = _denied(error)
                            ? widget.encounterType == 'referral'
                                  ? 'Specialist encounter access is unavailable or expired. Ask the patient to open this referral’s Specialist appointment and approve the exact current visit if eligible, then retry. Closed or invalid referrals cannot be bypassed. Your proposed text is retained.'
                                  : 'Encounter approval is unavailable or expired. Ask the patient to reapprove this exact visit in Care permissions, then retry. Your proposed text is retained.'
                            : _safeMessage(error);
                      });
                    }
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
          child: Text(
            _saving
                ? 'Saving…'
                : _error != null
                ? 'Retry save'
                : widget.previous == null
                ? 'Create final record'
                : 'Finalise correction',
          ),
        ),
      ],
    ),
  );
  Widget _field(TextEditingController controller, String label, int max) =>
      TextFormField(
        controller: controller,
        enabled: !_saving && !_attempted,
        onChanged: (_) {
          InactivitySession.reportActivity(context);
          _confirmed = false;
        },
        minLines: label.startsWith('Correction') ? 2 : 3,
        maxLines: null,
        maxLength: max,
        decoration: InputDecoration(labelText: label),
        validator: (text) => text == null || text.length > max
            ? 'Maximum $max characters'
            : (controller == _notes || controller == _correction) &&
                  text.trim().isEmpty
            ? controller == _notes
                  ? 'Consultation notes are required'
                  : 'Correction reason is required'
            : null,
      );
}
