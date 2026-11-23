import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';
import 'referral_repository.dart';
import '../../shared/data/history_page.dart';
import '../records/record_repository.dart';
import '../records/record_support.dart';

class SharedRecord {
  const SharedRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class ReferralRecordSharing extends StatefulWidget {
  const ReferralRecordSharing({
    super.key,
    required this.repository,
    required this.referral,
    required this.patientMode,
  });
  final FirestoreReferralRepository repository;
  final ReferralEntry referral;
  final bool patientMode;
  @override
  State<ReferralRecordSharing> createState() => _ReferralRecordSharingState();
}

class _ReferralRecordSharingState extends State<ReferralRecordSharing> {
  final ClinicalReadScope _scope = ClinicalReadScope();
  @override
  void initState() {
    super.initState();
    ClinicalCrypto.instance?.addListener(_locked);
  }

  void _locked() {
    if (ClinicalCrypto.instance?.unlocked == false) {
      _scope.close();
      shares.clear();
      _descriptions.clear();
      service.clearDirectoryCache();
      if (mounted) {
        setState(() {
          open = false;
          busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _scope.close();
    shares.clear();
    _descriptions.clear();
    service.clearDirectoryCache();
    ClinicalCrypto.instance?.removeListener(_locked);
    super.dispose();
  }

  Future<String> _candidate(
    QueryDocumentSnapshot<Map<String, dynamic>> c,
  ) async {
    try {
      return await service.candidateDescription(
        RecordSummary.fromData(c.id, c.data()),
      );
    } catch (_) {
      return 'Historical version ${c.id}: metadata unavailable. Preview/review required.';
    }
  }

  bool open = false, busy = false;
  String? message;
  List<SharedRecord> shares = [];
  String? next;
  final _descriptions = <String, Future<String>>{};
  late final service = RecordSharingService(
    widget.repository.db,
    widget.repository.auth,
  );
  Future<void> load({bool more = false}) async {
    setState(() {
      open = true;
      busy = true;
      message = null;
    });
    try {
      final result = await service.list(
        widget.referral,
        widget.patientMode,
        after: more ? next : null,
      );
      if (mounted) {
        setState(() {
          _descriptions.clear();
          shares = [if (more) ...shares, ...result.items];
          next = result.next;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          shares = [];
          message = 'Shared records are unavailable for the current referral, consent or connection.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> share() async {
    setState(() => busy = true);
    try {
      final firstPage = await service.eligible(widget.referral);
      var candidates = firstPage.items;
      var cursor = firstPage.next;
      var loadingMore = false;
      String? pageError;
      final labels = <String, Future<String>>{};
      service.clearDirectoryCache();
      if (!mounted || !_scope.active) return;
      final selected = await showClinicalDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => SimpleDialog(
            title: const Text('Share one encrypted record version'),
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Only encrypted, patient-visible records from this referral’s source encounter are eligible. Preview and confirm a version for the named specialist below. This version expires within 24 hours and remains subject to consent and referral access. Sharing does not include future corrections. Internal notes are never shared. Previously downloaded information cannot be recalled.',
                ),
              ),
              if (candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No eligible encrypted records. Ask the original author to append a reviewed encrypted version if the source is legacy plaintext.',
                  ),
                ),
              for (final c in candidates)
                SimpleDialogOption(
                  onPressed: () async {
                    try {
                      final repo = FirestoreRecordRepository(
                        widget.repository.db,
                        widget.repository.auth,
                      );
                      final summary = RecordSummary.fromData(c.id, c.data());
                      final record = await repo.getRecord(c.id);
                      final current = await repo.currentVersion(summary);
                      final attribution = await repo.attribution(summary);
                      String? provider = attribution['provider'],
                          clinic = attribution['clinic'];
                      try {
                        provider ??= await repo.providerName(summary.authorId);
                      } on FirebaseException catch (e) {
                        if (e.code != 'permission-denied') rethrow;
                      }
                      try {
                        clinic ??= await repo.clinicName(summary.clinicId);
                      } on FirebaseException catch (e) {
                        if (e.code != 'permission-denied') rethrow;
                      }
                      final specialist = await widget.repository.providerName(
                        widget.referral.specialistId,
                        widget.referral.destinationClinicId ??
                            widget.referral.clinicId,
                      );
                      if (!context.mounted || !_scope.active) {
                        record.content.clear();
                        return;
                      }
                      final confirmed = await showClinicalDialog<bool>(
                        context: context,
                        clear: record.content.clear,
                        builder: (previewContext) => AlertDialog(
                          title: const Text('Confirm selected version sharing'),
                          content: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'To: ${specialist ?? 'Named specialist (name unavailable)'}',
                                ),
                                Text(
                                  '${summary.type} · ${recordDate(summary.visitAt)} · ${clinic ?? 'Historical clinic unavailable'} · provider ${provider ?? 'Name unavailable'} · revision ${summary.revision}',
                                ),
                                Text(
                                  current.id == summary.id
                                      ? 'Current version'
                                      : 'Historical version — a newer correction exists (revision ${current.revision}).',
                                ),
                                const Text(
                                  'Only this version is selected. Future corrections require another explicit share. Author-only notes are excluded.',
                                ),
                                for (final field in [
                                  'notes',
                                  'diagnoses',
                                  'prescriptions',
                                  'medications',
                                  'labResultMetadata',
                                  'correctionReason',
                                ])
                                  if (record.content[field] != null)
                                    Text('$field: ${record.content[field]}'),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(previewContext, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(previewContext, true),
                              child: const Text('Share this version'),
                            ),
                          ],
                        ),
                      );
                      if (context.mounted && confirmed == true) {
                        Navigator.pop(context, c.id);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        update(
                          () => pageError = 'Preview unavailable. Unlock encryption, refresh consent and retry.',
                        );
                      }
                    }
                  },
                  child: FutureBuilder<String>(
                    future: labels.putIfAbsent(c.id, () => _candidate(c)),
                    builder: (_, snapshot) => Text(
                      snapshot.data ??
                          '${c.data()['recordType']} · ${recordDate(c.data()['visitAt'] is Timestamp ? (c.data()['visitAt'] as Timestamp).toDate() : null)} · revision ${c.data()['revision']} · provider/version status unavailable or loading · preview before sharing',
                    ),
                  ),
                ),
              if (pageError != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(pageError!),
                ),
              if (candidates.length >= 200)
                const Text(
                  '200 candidate limit reached. Close this view to release metadata; request reviewed access for older versions.',
                ),
              if (cursor != null && candidates.length < 200)
                TextButton(
                  onPressed: loadingMore
                      ? null
                      : () async {
                          update(() {
                            loadingMore = true;
                            pageError = null;
                          });
                          try {
                            final page = await service.eligible(
                              widget.referral,
                              after: cursor,
                            );
                            if (!context.mounted) return;
                            update(() {
                              candidates = [...candidates, ...page.items];
                              cursor = page.next;
                            });
                          } catch (_) {
                            if (context.mounted) {
                              update(
                                () => pageError = 'More records could not be loaded. Reconnect and retry.',
                              );
                            }
                          } finally {
                            if (context.mounted) {
                              update(() => loadingMore = false);
                            }
                          }
                        },
                  child: Text(
                    loadingMore
                        ? 'Loading records…'
                        : 'Load more eligible records',
                  ),
                ),
            ],
          ),
        ),
      );
      if (selected != null) {
        await service.share(widget.referral, selected);
        await load();
        if (mounted) {
          setState(
            () => message =
                'Selected record version shared with the named specialist.',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is ClinicalCryptoFailure ? e.message : 'Record was not shared. Check current consent, referral, source record and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke(String id) async {
    setState(() => busy = true);
    try {
      await service.revoke(id);
      await load();
      if (mounted) {
        setState(
          () => message = 'Future shared-record reads revoked. Previously copied information cannot be erased.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Revocation was not confirmed. Reconnect and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> read(SharedRecord share) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final clear = await service.read(share.id);
      final description = await service.description(share);
      if (!mounted || !_scope.active) {
        clear.clear();
        return;
      }
      await showClinicalDialog<void>(
        context: context,
        clear: clear.clear,
        authorised: () async {
          final allowed = await service.stillReadable(share.id);
          if (!allowed && mounted) {
            setState(() {
              shares = [];
              _descriptions.clear();
              message = 'Share access changed. The clinical view was closed. Refresh or ask the patient to review consent and this selected version.';
            });
          }
          return allowed;
        },
        builder: (context) => AlertDialog(
          title: const Text('Shared medical record version'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const Text(
                  'This selected version excludes internal notes. Future corrections are not automatically shared.',
                ),
                for (final e in clear.entries) Text('${e.key}: ${e.value}'),
              ],
            ),
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
          () => message = 'Record unavailable. Consent, referral or share may have expired or been revoked.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: busy ? null : load,
        child: Text(open ? 'Refresh shared records' : 'Shared records'),
      ),
      if (open) ...[
        if (widget.patientMode && widget.referral.status == 'accepted')
          OutlinedButton(
            onPressed: busy ? null : share,
            child: const Text('Share a selected record'),
          ),
        if (shares.isEmpty && !busy) const Text('No shared record versions.'),
        for (final s in shares)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Medical record · ${s.data['status']}'),
            subtitle: FutureBuilder<String>(
              future: _descriptions.putIfAbsent(
                s.id,
                () => service.description(s),
              ),
              builder: (_, snapshot) => Text(
                '${snapshot.data ?? 'Version metadata unavailable or loading; refresh to retry.'}\nExpires ${(s.data['expiresAt'] as Timestamp).toDate().toLocal()}',
              ),
            ),
            trailing: widget.patientMode
                ? TextButton(
                    onPressed: busy || s.data['status'] != 'active'
                        ? null
                        : () => revoke(s.id),
                    child: const Text('Revoke'),
                  )
                : TextButton(
                    onPressed: busy ? null : () => read(s),
                    child: const Text('Open record'),
                  ),
          ),
        if (next != null)
          TextButton(
            onPressed: busy ? null : () => load(more: true),
            child: const Text('Load more shared records'),
          ),
      ],
      if (busy) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ],
  );
}

class RecordSharingService {
  RecordSharingService(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final _directory = <String, Future<String?>>{};
  final _heads = <String, Future<RecordSummary>>{};
  void clearDirectoryCache() {
    _directory.clear();
    _heads.clear();
  }

  Future<String> candidateDescription(RecordSummary summary) async {
    final repo = FirestoreRecordRepository(db, auth);
    final names = await repo.attribution(summary);
    Future<String?> directoryName(
      String key,
      Future<String?> Function() read,
    ) => _directory.putIfAbsent(key, () async {
      try {
        return await read();
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        return null;
      }
    });
    final provider =
        names['provider'] ??
        await directoryName(
          'provider-${summary.authorId}',
          () => repo.providerName(summary.authorId),
        );
    final clinic =
        names['clinic'] ??
        await directoryName(
          'clinic-${summary.clinicId}',
          () => repo.clinicName(summary.clinicId),
        );
    final current = await _heads.putIfAbsent(
      summary.root,
      () => repo.currentVersion(summary),
    );
    return '${summary.type} · ${recordDate(summary.visitAt)} · ${clinic ?? 'Historical clinic unavailable'} · provider ${provider ?? 'Historical name unavailable'} · revision ${summary.revision} · ${current.id == summary.id ? 'Current version' : 'Historical version; newer correction exists'} · preview before sharing';
  }

  String get uid => auth.currentUser!.uid;
  Future<HistoryPage<SharedRecord>> list(
    ReferralEntry referral,
    bool patientMode, {
    String? after,
  }) async {
    Query<Map<String, dynamic>> query = db
        .collection('record_share_index')
        .where('referralId', isEqualTo: referral.id)
        .where(patientMode ? 'patientId' : 'specialistId', isEqualTo: uid)
        .where(
          'destinationClinicId',
          isEqualTo: referral.destinationClinicId ?? referral.clinicId,
        )
        .orderBy(FieldPath.documentId)
        .limit(20);
    if (after != null) query = query.startAfter([after]);
    final page = await query.get(const GetOptions(source: Source.server));
    final rows = <SharedRecord>[];
    for (final pointer in page.docs) {
      try {
        final data =
            (await db
                    .doc('record_shares/${pointer.id}')
                    .get(const GetOptions(source: Source.server)))
                .data();
        if (data != null) rows.add(SharedRecord(pointer.id, data));
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
      }
    }
    return HistoryPage(rows, page.docs.length == 20 ? page.docs.last.id : null);
  }

  Future<HistoryPage<QueryDocumentSnapshot<Map<String, dynamic>>>> eligible(
    ReferralEntry referral, {
    String? after,
  }) async {
    var query = db
        .collection('record_summaries')
        .where('patientId', isEqualTo: uid)
        .where('patientVisible', isEqualTo: true)
        .where('clinicId', isEqualTo: referral.clinicId)
        .where('encounterType', isEqualTo: 'appointment')
        .where('encounterId', isEqualTo: referral.sourceAppointmentId)
        .orderBy(FieldPath.documentId)
        .limit(20);
    if (after != null) query = query.startAfter([after]);
    final candidates = await query.get(const GetOptions(source: Source.server));
    // Metadata suffices for discovery. Preview/final sharing checks encryption
    // and current authority; do not fetch every clinical payload to list choices.
    final result = candidates.docs;
    return HistoryPage(
      result,
      candidates.docs.length == 20 ? candidates.docs.last.id : null,
    );
  }

  Future<void> share(ReferralEntry referral, String recordId) async {
    final scope = ClinicalReadScope();
    final original =
        (await db
                .doc('medical_records/$recordId')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (original == null ||
        (original['content'] as Map)['format'] != 'medisync-clinical-v1') {
      throw const ClinicalCryptoFailure(
        'Legacy plaintext cannot be silently migrated or shared. Request an encrypted correction from the original author.',
      );
    }
    final content = await ClinicalCrypto.instance!.grantRecipient(
      Map<String, dynamic>.from(original['content'] as Map),
      ClinicalCrypto.context('record', recordId, original),
      referral.specialistId,
    );
    final id = '${referral.id}-$recordId',
        ref = db.doc('record_shares/${referral.id}-$recordId');
    final attribution =
        (await db
                .doc('record_attribution/$recordId')
                .get(const GetOptions(source: Source.server)))
            .data() ??
        {'recordId': recordId};
    await db.runTransaction((tx) async {
      scope.check();
      final old = (await tx.get(ref)).data();
      scope.check();
      final data = {
        'shareId': id,
        'referralId': referral.id,
        'recordId': recordId,
        for (final k in [
          'clinicId',
          'patientId',
          'authorId',
          'encounterType',
          'encounterId',
          'revision',
        ])
          k: original[k],
        'specialistId': referral.specialistId,
        'destinationClinicId':
            referral.destinationClinicId ?? referral.clinicId,
        'status': 'active',
        'createdAt': old?['createdAt'] ?? FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
          DateTime.now().toUtc().add(const Duration(hours: 23, minutes: 55)),
        ),
        'shareRevision': (old?['shareRevision'] as int? ?? 0) + 1,
        'content': content,
      };
      tx.set(ref, data);
      tx.set(db.doc('record_share_index/$id'), _index(data));
      final metadata = {
        'shareId': id,
        'recordId': recordId,
        'rootRecordId': original['rootRecordId'] ?? recordId,
        'visitAt': original['visitAt'],
        'createdAt': original['createdAt'],
        'recordType': original['recordType'],
        'attribution': attribution,
      };
      tx.set(db.doc('record_share_details/$id'), metadata);
      tx.set(
        db.doc(
          'record_head_readers/${original['rootRecordId'] ?? recordId}/specialists/${referral.specialistId}',
        ),
        {
          'shareId': id,
          'rootRecordId': original['rootRecordId'] ?? recordId,
          for (final k in [
            'referralId',
            'patientId',
            'specialistId',
            'destinationClinicId',
            'status',
            'expiresAt',
          ])
            k: data[k],
        },
      );
    });
  }

  Map<String, dynamic> _index(Map<String, dynamic> data) => {
    for (final k in [
      'shareId',
      'referralId',
      'patientId',
      'specialistId',
      'destinationClinicId',
      'status',
      'shareRevision',
      'updatedAt',
    ])
      k: data[k],
  };
  Future<void> revoke(String id) => db.runTransaction((tx) async {
    final ref = db.doc('record_shares/$id'), old = (await tx.get(ref)).data();
    if (old == null) throw StateError('Share unavailable');
    final source = (await tx.get(db.doc('medical_records/${old['recordId']}')))
        .data()!;
    final readerRef = db.doc(
      'record_head_readers/${source['rootRecordId'] ?? source['recordId']}/specialists/${old['specialistId']}',
    );
    final reader = (await tx.get(readerRef)).data();
    final changes = {
      'status': 'revoked',
      'updatedAt': FieldValue.serverTimestamp(),
      'shareRevision': (old['shareRevision'] as int) + 1,
    };
    tx.update(ref, changes);
    tx.set(db.doc('record_share_index/$id'), _index({...old, ...changes}));
    if (reader?['shareId'] == id) tx.update(readerRef, {'status': 'revoked'});
  });
  Future<String> description(SharedRecord share) async {
    final data =
        (await db
                .doc('record_share_details/${share.id}')
                .get(const GetOptions(source: Source.server)))
            .data();
    String? provider;
    provider = (data?['attribution'] as Map?)?['providerName'] as String?;
    try {
      provider ??= await FirestoreRecordRepository(
        db,
        auth,
      ).providerName(share.data['authorId'] as String);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      // Disambiguate unavailable head metadata from loss of the clinical share.
      if (!await stillReadable(share.id)) rethrow;
    }
    if (data == null) {
      return 'Revision ${share.data['revision']} · provider ${provider ?? 'historical name unavailable'} · historical visit/type metadata unavailable. Ask the patient to review and explicitly share the desired version again.';
    }
    Map<String, dynamic>? head;
    try {
      head =
          (await db
                  .doc('record_heads/${data['rootRecordId']}')
                  .get(const GetOptions(source: Source.server)))
              .data();
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      return '${data['recordType']} · visit ${recordDate((data['visitAt'] as Timestamp).toDate())} · provider ${provider ?? 'historical name unavailable'} · revision ${share.data['revision']} · Current-version status unavailable. Ask the patient to review later corrections; they require explicit sharing.';
    }
    return '${data['recordType']} · visit ${recordDate((data['visitAt'] as Timestamp).toDate())} · provider ${provider ?? 'historical name unavailable'} · revision ${share.data['revision']} · ${head != null && head['revision'] > share.data['revision'] ? 'Historical version — a newer correction exists (revision ${head['revision']}). Ask the patient to explicitly share it.' : 'Latest known version; future corrections are not automatically shared.'}';
  }

  Future<Map<String, dynamic>> read(String id) async {
    final data =
        (await db
                .doc('record_shares/$id')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (data == null) throw StateError('Share unavailable');
    return validateClinicalContent(
      await ClinicalCrypto.instance!.decrypt(
        Map<String, dynamic>.from(data['content'] as Map),
        ClinicalCrypto.context('record', data['recordId'] as String, {
          for (final k in [
            'clinicId',
            'patientId',
            'authorId',
            'encounterType',
            'encounterId',
            'revision',
          ])
            k: data[k],
        }),
      ),
    );
  }

  Future<bool> stillReadable(String id) async {
    try {
      return (await db
              .doc('record_shares/$id')
              .get(const GetOptions(source: Source.server)))
          .exists;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return false;
      rethrow;
    }
  }
}
