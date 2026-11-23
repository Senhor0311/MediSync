import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/data/history_page.dart';
import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'record_repository.dart';
import 'record_support.dart';
import 'save_readable_stub.dart'
    if (dart.library.js_interop) 'save_readable_web.dart';

/// A resumable, memory-only export. A failed page never advances its cursor.
class MedicalExport {
  MedicalExport(
    this.repository,
    this.patientId, {
    this.maxVersions = 500,
    this.maxCharacters = 700000,
  });
  final RecordRepository repository;
  final String patientId;
  final int maxVersions, maxCharacters;
  final metadataFailures = <String, String>{};
  ClinicalReadScope _scope = ClinicalReadScope();
  Future<void>? _pending;
  int _generation = 0, retainedCharacters = 0;
  bool limitReached = false;
  int segment = 1;
  bool _segmented = false;
  bool get active => _active && _scope.active;
  final records = <String, MedicalRecord>{};
  final summaries = <String, RecordSummary>{};
  final failures = <String>{};
  final names = <String, Map<String, String>>{};
  final current = <String, String>{};
  final _resolvedRoots = <String>{};
  final _coveredIds = <String>{};
  final unlistedIds = <String>{};
  int get unavailableCount =>
      {...failures, ...metadataFailures.keys, ...unlistedIds}.length;
  String? cursor;
  String? _coverageCursor;
  bool _historyDone = false, _coverageDone = false;
  bool exhausted = false, pageFailed = false;
  bool _active = true;
  bool get complete =>
      exhausted &&
      !pageFailed &&
      !limitReached &&
      !_segmented &&
      failures.isEmpty &&
      unlistedIds.isEmpty &&
      metadataFailures.isEmpty;

  Future<void> nextPage() {
    if (_pending != null) return _pending!;
    final pending = _nextPage();
    _pending = pending;
    return pending.whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    });
  }

  Future<void> _nextPage() async {
    if (exhausted || !active || limitReached) return;
    final generation = _generation;
    bool valid() => active && generation == _generation;
    if ({...summaries.keys, ...metadataFailures.keys}.length >= maxVersions ||
        _coveredIds.length >= maxVersions * 2) {
      limitReached = true;
      return;
    }
    pageFailed = false;
    try {
      if (!_historyDone) {
        final page = await (repository as HistoryPager<RecordSummary>)
            .historyPage(after: cursor, scope: {'patientId': patientId});
        if (!valid()) return;
        metadataFailures.addAll(page.unavailable);
        for (final summary in page.items) {
          if (!valid()) return;
          if (summary.patientId != patientId || !summary.patientVisible) {
            throw const RecordFailure('Export scope validation failed.');
          }
          summaries[summary.id] = summary;
          await _read(summary);
          // Retry a size-limited page from the same cursor in the next segment;
          // version references make overlapping rows explicit, never omitted.
          if (limitReached) return;
        }
        if (!valid()) return;
        cursor = page.next;
        _historyDone = page.next == null;
      }
      if (repository is MedicalExportCoverage && !_coverageDone) {
        final page = await (repository as MedicalExportCoverage)
            .visibleRecordIdsPage(after: _coverageCursor);
        if (!valid()) return;
        _coveredIds.addAll(page.items);
        _coverageCursor = page.next;
        _coverageDone = page.next == null;
      } else if (repository is! MedicalExportCoverage) {
        _coverageDone = true;
      }
      exhausted = _historyDone && _coverageDone;
      if (exhausted && !_segmented) {
        unlistedIds.addAll(_coveredIds.difference(summaries.keys.toSet()));
      }
    } catch (_) {
      if (!valid()) return;
      pageFailed = true;
      rethrow;
    }
  }

  Future<void> _read(RecordSummary summary) async {
    final generation = _generation;
    bool valid() => active && generation == _generation;
    try {
      final record = await repository.getRecord(summary.id);
      if (!valid()) return;
      if (record.summary.patientId != patientId ||
          !record.summary.patientVisible) {
        throw const RecordFailure('Export scope validation failed.');
      }
      if (repository is RecordVersions) {
        final versions = repository as RecordVersions;
        try {
          if (_resolvedRoots.add(summary.root)) {
            final head = await versions.currentVersion(summary);
            if (!valid()) return;
            current[summary.root] = head.id;
          }
          names[summary.id] = await versions.attribution(summary);
        } catch (error) {
          if (error is FirebaseException && error.code == 'permission-denied') {
            rethrow;
          }
          if (valid()) metadataFailures[summary.id] = 'Current head or historical attribution unavailable. Clinical content below is retained; completeness is not claimed.';
        }
        if (!valid()) return;
      }
      final size = jsonEncode(record.content).length;
      if (retainedCharacters + size > maxCharacters) {
        limitReached = true;
        throw const RecordFailure(
          'Export memory limit reached. Save the clearly marked partial export and request reviewed fulfilment for the remaining history.',
        );
      }
      retainedCharacters += size;
      records[summary.id] = MedicalRecord(record.summary, record.content);
      failures.remove(summary.id);
    } catch (error) {
      if (!valid()) return;
      if (error is FirebaseException && error.code == 'permission-denied') {
        clear();
        rethrow;
      }
      failures.add(summary.id);
      records.remove(summary.id);
    }
  }

  Future<void> retryFailures() async {
    if (!active || _pending != null || limitReached) return;
    for (final id in failures.take(20).toList()) {
      if (!active) return;
      await _read(summaries[id]!);
    }
  }

  String get text {
    final lines = <String>[
      'MediSync — patient medical records',
      if (_segmented)
        'Segment $segment. Preserve every earlier file. This file is not a unified complete history; cross-segment coverage requires reviewed reconciliation.',
      complete
          ? 'COMPLETE authorised record history as read during this export.'
          : 'INCOMPLETE — do not treat as a complete history.',
      'Export generated: ${recordDate(DateTime.now())}',
      'Pages are bounded to 20 versions. This is not an atomic snapshot; refresh for later corrections.',
      if (limitReached)
        'INCOMPLETE: local safety limit reached ($maxVersions versions / $maxCharacters clinical characters). Save this partial export, then continue with a new memory-only segment or request reviewed fulfilment.',
      for (final entry in metadataFailures.entries)
        'UNAVAILABLE historical version ${entry.key}: ${entry.value}',
      if (!exhausted || pageFailed)
        'UNAVAILABLE: remaining history. Reconnect and continue.',
      'Excluded: author-only internal notes, private keys, attachments and other patients. Attachments are not implemented.',
      if (unlistedIds.isNotEmpty)
        'UNAVAILABLE: ${unlistedIds.length} historical versions lack usable chronological metadata or a matching visible summary. Their dates/content have not been invented. Request a reviewed historical export.',
      for (final id in unlistedIds)
        'Unavailable historical version — reference $id; visit date and version details unavailable.',
    ];
    final ordered = summaries.values.toList()
      ..sort((a, b) {
        final date = b.visitAt.compareTo(a.visitAt);
        return date != 0 ? date : b.id.compareTo(a.id);
      });
    for (final s in ordered) {
      lines.addAll([
        '',
        '${s.type == 'visit' ? 'Consultation' : 'Follow-up'} · revision ${s.revision} · ${current[s.root] == null
            ? 'Current status unavailable'
            : current[s.root] == s.id
            ? 'Current version'
            : 'Historical version'}',
        'Version reference: ${s.id} · root: ${s.root}',
        'Visit: ${recordDate(s.visitAt)}${s.dateSource == null || s.dateSource == 'legacy-preserved' ? ' (legacy recorded date; provenance unverified)' : ''}',
        '${s.revision > 1 ? 'Amendment created' : 'Record created'}: ${recordDate(s.createdAt)}',
        'Clinic: ${names[s.id]?['clinic'] ?? 'Historical name unavailable'}',
        'Provider: ${names[s.id]?['provider'] ?? 'Historical name unavailable'}',
      ]);
      final record = records[s.id];
      if (record == null) {
        lines.add(
          'UNAVAILABLE: this version could not be read or decrypted. Retry after unlocking/reconnecting.',
        );
        continue;
      }
      for (final field in const {
        'notes': 'Consultation notes',
        'diagnoses': 'Diagnoses',
        'prescriptions': 'Prescriptions',
        'medications': 'Medications',
        'labResultMetadata': 'Written laboratory results',
        'correctionReason': 'Correction reason',
      }.entries) {
        final value = record.content[field.key];
        lines.add(
          '${field.value}: ${value is List
              ? value.isEmpty
                    ? 'None recorded'
                    : value.join('\n')
              : value ?? 'None recorded'}',
        );
      }
    }
    return lines.join('\n');
  }

  String get html =>
      '<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'"><title>Medical records</title><style>body{font:16px system-ui;margin:2rem;max-width:70rem}pre{white-space:pre-wrap;overflow-wrap:anywhere}@media print{.guidance{display:none}}</style></head><body><p class="guidance">Use your browser menu: Print / save as PDF.</p><pre>${const HtmlEscape().convert(text)}</pre></body></html>';
  void clear() {
    _generation++;
    _scope.close();
    _active = false;
    records.clear();
    summaries.clear();
    failures.clear();
    names.clear();
    current.clear();
    _resolvedRoots.clear();
    _coveredIds.clear();
    unlistedIds.clear();
    metadataFailures.clear();
    retainedCharacters = 0;
  }

  void restart() {
    clear();
    _active = true;
    _scope = ClinicalReadScope();
    limitReached = false;
    cursor = null;
    _coverageCursor = null;
    _historyDone = false;
    _coverageDone = false;
    exhausted = false;
    pageFailed = false;
    segment = 1;
    _segmented = false;
  }

  /// Explicitly release a saved segment while preserving both server cursors.
  /// No unified completeness assertion can be made after earlier buffers leave
  /// the app; exported files must be reconciled by their version references.
  void nextSegment() {
    if (!active || !limitReached || _pending != null) return;
    final nextHistory = cursor, nextCoverage = _coverageCursor;
    final historyDone = _historyDone, coverageDone = _coverageDone;
    final nextSegment = segment + 1;
    restart();
    cursor = nextHistory;
    _coverageCursor = nextCoverage;
    _historyDone = historyDone;
    _coverageDone = coverageDone;
    segment = nextSegment;
    _segmented = true;
  }
}

class MedicalExportDialog extends StatefulWidget {
  const MedicalExportDialog({super.key, required this.export});
  final MedicalExport export;
  @override
  State<MedicalExportDialog> createState() => _MedicalExportDialogState();
}

class _MedicalExportDialogState extends State<MedicalExportDialog> {
  bool busy = false;
  Timer? _authority;
  bool _checking = false;
  String? message;
  @override
  void initState() {
    super.initState();
    ClinicalCrypto.instance?.addListener(_lock);
    _authority = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_checking ||
          busy ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      _checking = true;
      try {
        await widget.export.repository.listPatient(widget.export.patientId);
      } on FirebaseException catch (error) {
        if (error.code == 'permission-denied') _close();
      } catch (_) {
        /* Offline is not proof of revocation; next action checks. */
      } finally {
        _checking = false;
      }
    });
  }

  void _close() {
    clearReadable();
    widget.export.clear();
    if (mounted) {
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    }
  }

  void _lock() {
    if (ClinicalCrypto.instance?.unlocked == false && mounted) {
      _close();
    }
  }

  @override
  void dispose() {
    ClinicalCrypto.instance?.removeListener(_lock);
    _authority?.cancel();
    clearReadable();
    widget.export.clear();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.export.retryFailures();
      // One deliberate action reads at most 10 pages (200 versions). Continue
      // remains available; there is no unbounded quota-consuming request.
      for (
        var i = 0;
        i < 10 &&
            !widget.export.exhausted &&
            !widget.export.limitReached &&
            widget.export.active &&
            mounted;
        i++
      ) {
        await widget.export.nextPage();
        if (!widget.export.active) {
          _close();
          return;
        }
        if (mounted) setState(() {});
      }
    } catch (_) {
      message = 'History page unavailable. Loaded sections are retained. Reconnect and continue; unavailable content remains explicitly marked.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Readable medical-record export'),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Contains decrypted information. Save or print only to a private destination. Internal notes are excluded. Close or lock to clear this memory-only view.',
            ),
            if (busy) const LinearProgressIndicator(),
            if (message != null) Text(message!),
            Text(
              '${widget.export.summaries.length} versions loaded · ${widget.export.unavailableCount} unavailable',
            ),
            SelectableText(widget.export.text),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.export.limitReached)
        TextButton(
          onPressed: busy
              ? null
              : () {
                  widget.export.nextSegment();
                  load();
                },
          child: const Text(
            'Next segment — save this file first; clears loaded text',
          ),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(busy ? 'Cancel export and close' : 'Close'),
      ),
      TextButton(
        onPressed: busy
            ? null
            : () {
                if (widget.export.complete ||
                    widget.export.exhausted &&
                        (widget.export.unlistedIds.isNotEmpty ||
                            widget.export.metadataFailures.isNotEmpty)) {
                  widget.export.restart();
                }
                load();
              },
        child: Text(
          widget.export.complete
              ? 'Refresh complete export'
              : 'Load / continue / retry export',
        ),
      ),
      FilledButton(
        onPressed:
            busy || widget.export.summaries.isEmpty && !widget.export.exhausted
            ? null
            : () async {
                if (busy || !widget.export.active) return;
                setState(() => busy = true);
                try {
                  final html = widget.export.html;
                  if (html.length > 5000000) {
                    if (mounted) {
                      setState(
                        () => message = 'Printable output exceeds the local save size limit. This export remains incomplete if limited; request reviewed fulfilment for a smaller or segmented export.',
                      );
                    }
                    return;
                  }
                  await saveReadable(html);
                  if (mounted) {
                    setState(
                      () => message = 'Printable medical record saved to your chosen destination.',
                    );
                  }
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => message = 'Download unavailable or cancelled. The readable view is retained; retry saving on Android or web.',
                    );
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
        child: Text(
          widget.export.complete
              ? 'Download printable record'
              : 'Download clearly marked partial record',
        ),
      ),
    ],
  );
}
