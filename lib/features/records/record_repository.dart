import '../../shared/data/history_page.dart';
import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';
import 'record_support.dart';
import '../../shared/data/server_transaction.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RecordSummary {
  const RecordSummary({
    required this.id,
    required this.clinicId,
    required this.patientId,
    required this.authorId,
    required this.type,
    required this.visitAt,
    required this.patientVisible,
    required this.encounterType,
    required this.encounterId,
    this.revision = 1,
    this.rootRecordId,
    this.supersedesId,
    this.createdAt,
    this.dateSource,
  });
  final String id,
      clinicId,
      patientId,
      authorId,
      type,
      encounterType,
      encounterId;
  final DateTime visitAt;
  final bool patientVisible;
  final int revision;
  final String? rootRecordId, supersedesId;
  final DateTime? createdAt;
  final String? dateSource;
  String get root => rootRecordId ?? id;

  static RecordSummary fromData(String id, Map<String, dynamic> data) {
    if (!_validId(id) ||
        data['recordId'] != id ||
        data['clinicId'] is! String ||
        data['patientId'] is! String ||
        data['authorId'] is! String ||
        !['visit', 'follow_up'].contains(data['recordType']) ||
        data['status'] != 'final' ||
        data['revision'] is! int ||
        (data['revision'] as int) < 1 ||
        (data['revision'] as int) > 1000 ||
        data['revision'] == 1 &&
            (data['supersedesId'] != null ||
                data['rootRecordId'] != null && data['rootRecordId'] != id) ||
        data['revision'] is int &&
            (data['revision'] as int) > 1 &&
            (data['rootRecordId'] == null || data['supersedesId'] == null) ||
        data['visitAt'] is! Timestamp ||
        data['patientVisible'] is! bool ||
        !['appointment', 'referral'].contains(data['encounterType']) ||
        data['encounterId'] is! String ||
        !_validId(data['encounterId'] as String) ||
        [
          'clinicId',
          'patientId',
          'authorId',
        ].any((k) => !_validId(data[k] as String)) ||
        data['rootRecordId'] != null &&
            (data['rootRecordId'] is! String ||
                !_validId(data['rootRecordId'] as String)) ||
        data['supersedesId'] != null &&
            (data['supersedesId'] is! String ||
                !_validId(data['supersedesId'] as String)) ||
        data['createdAt'] != null && data['createdAt'] is! Timestamp ||
        data['dateSource'] != null &&
            !['encounter', 'legacy-preserved'].contains(data['dateSource'])) {
      throw const FormatException('Invalid record summary');
    }
    return RecordSummary(
      id: id,
      clinicId: data['clinicId'] as String,
      patientId: data['patientId'] as String,
      authorId: data['authorId'] as String,
      type: data['recordType'] as String,
      visitAt: (data['visitAt'] as Timestamp).toDate(),
      patientVisible: data['patientVisible'] as bool,
      encounterType: data['encounterType'] as String,
      encounterId: data['encounterId'] as String,
      revision: data['revision'] as int,
      rootRecordId: data['rootRecordId'] as String?,
      supersedesId: data['supersedesId'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      dateSource: data['dateSource'] as String?,
    );
  }
}

class MedicalRecord {
  const MedicalRecord(this.summary, this.content, {this.internalNotes});
  final RecordSummary summary;
  final Map<String, dynamic> content;
  final String? internalNotes;
}

class RecordDraft {
  const RecordDraft({
    required this.clinicId,
    required this.patientId,
    required this.type,
    required this.patientVisible,
    required this.notes,
    required this.encounterType,
    required this.encounterId,
    this.diagnosis = '',
    this.prescription = '',
    this.medication = '',
    this.labResult = '',
    this.internalNotes = '',
    this.correctionReason = '',
    this.operationId,
    this.preservedItems = const {},
  });
  final String clinicId,
      patientId,
      type,
      notes,
      diagnosis,
      prescription,
      medication,
      labResult;
  final String internalNotes;
  final String correctionReason;
  final String encounterType, encounterId;
  final bool patientVisible;
  final String? operationId;
  final Map<String, List<String>> preservedItems;

  void validate({bool correction = false}) {
    if (notes.trim().isEmpty) {
      throw const RecordFailure('Enter consultation notes before finalising.');
    }
    if (notes.length > 5000 ||
        internalNotes.length > 5000 ||
        correctionReason.length > 200 ||
        [
          diagnosis,
          prescription,
          medication,
          labResult,
        ].any((t) => t.length > 2000)) {
      throw const RecordFailure('A field exceeds its permitted length.');
    }
    if (preservedItems.keys.any(
          (k) => ![
            'diagnoses',
            'prescriptions',
            'medications',
            'labResultMetadata',
          ].contains(k),
        ) ||
        preservedItems.values.any(
          (items) => items.length > 20 || items.join('\n').length > 2000,
        )) {
      throw const RecordFailure(
        'Clinical collections allow at most 20 items and 2000 characters per field.',
      );
    }
    if (correction && correctionReason.trim().isEmpty) {
      throw const RecordFailure('Enter a correction reason.');
    }
  }
}

abstract class RecordRepository {
  Future<List<RecordSummary>> listPatient(String patientId);
  Future<List<RecordSummary>> listPractitioner(
    String clinicId,
    String patientId, {
    required String encounterType,
    required String encounterId,
  });
  Future<MedicalRecord> getRecord(String id);
  Future<String?> clinicName(String clinicId);
  Future<String?> providerName(String providerId);
  Future<void> createFinal(RecordDraft draft);
}

abstract interface class RecordCorrections {
  Future<void> correct(RecordSummary previous, RecordDraft draft);
}

abstract interface class RecordVersions {
  Future<RecordSummary> currentVersion(RecordSummary record);
  Future<Map<String, String>> attribution(RecordSummary record);
}

abstract interface class MedicalExportCoverage {
  Future<HistoryPage<String>> visibleRecordIdsPage({String? after});
}

abstract interface class RecordReadRecovery {
  Future<void> reconnectReads();
}

abstract interface class RecordAuthority {
  Future<bool> stillAuthorised(RecordSummary summary);
}

class FirestoreRecordRepository
    implements
        RecordRepository,
        HistoryPager<RecordSummary>,
        RecordVersions,
        MedicalExportCoverage,
        RecordReadRecovery,
        RecordAuthority,
        RecordCorrections {
  const FirestoreRecordRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  @override
  Future<bool> stillAuthorised(RecordSummary summary) async {
    try {
      return (await db
              .doc('record_summaries/${summary.id}')
              .get(const GetOptions(source: Source.server)))
          .exists;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return false;
      rethrow;
    }
  }

  @override
  Future<void> reconnectReads() async {
    // Restart stale SDK read targets after a known denial and patient renewal.
    // Every subsequent read still requires fresh server Rules authorisation.
    await db.disableNetwork();
    await db.enableNetwork();
  }

  @override
  Future<HistoryPage<String>> visibleRecordIdsPage({String? after}) =>
      readHistoryPage(
        db
            .collection('medical_records')
            .where('patientId', isEqualTo: auth.currentUser!.uid)
            .where('patientVisible', isEqualTo: true),
        (id, _) => id,
        after: after,
      );

  @override
  Future<HistoryPage<RecordSummary>> historyPage({
    String? after,
    Map<String, String> scope = const {},
  }) {
    Query<Map<String, dynamic>> query = db
        .collection('record_summaries')
        .where(
          'patientId',
          isEqualTo: scope['patientId'] ?? auth.currentUser!.uid,
        );
    if (scope['clinicId'] == null) {
      query = query.where('patientVisible', isEqualTo: true);
    } else {
      query = query
          .where('clinicId', isEqualTo: scope['clinicId'])
          .where('encounterType', isEqualTo: scope['encounterType'])
          .where('encounterId', isEqualTo: scope['encounterId']);
    }
    return readRecordPage(query, RecordSummary.fromData, after: after);
  }

  @override
  Future<List<RecordSummary>> listPatient(String patientId) async {
    if (auth.currentUser?.uid != patientId) {
      throw const FormatException('Invalid patient scope');
    }
    return (await historyPage(scope: {'patientId': patientId})).items;
  }

  @override
  Future<List<RecordSummary>> listPractitioner(
    String clinicId,
    String patientId, {
    required String encounterType,
    required String encounterId,
  }) async {
    if (!_validId(clinicId) ||
        !_validId(patientId) ||
        !_validId(encounterId) ||
        !['appointment', 'referral'].contains(encounterType)) {
      throw const FormatException('Invalid scope');
    }
    return (await historyPage(
      scope: {
        'patientId': patientId,
        'clinicId': clinicId,
        'encounterType': encounterType,
        'encounterId': encounterId,
      },
    )).items;
  }

  @override
  Future<RecordSummary> currentVersion(RecordSummary record) async {
    final heads = await db
        .collection('record_heads')
        .where(FieldPath.documentId, isEqualTo: record.root)
        .limit(1)
        .get(const GetOptions(source: Source.server));
    final head = heads.docs.firstOrNull?.data();
    if (head == null) {
      if (record.rootRecordId == null && record.revision == 1) return record;
      throw const RecordFailure(
        'Current version status unavailable: required head is missing.',
      );
    }
    if (head['rootRecordId'] != record.root ||
        head['recordId'] is! String ||
        head['revision'] is! int ||
        (head['revision'] as int) < record.revision) {
      throw const RecordFailure('Current version metadata is invalid.');
    }
    if (head['recordId'] == record.id) return record;
    final current =
        (await db
                .doc('record_summaries/${head['recordId']}')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (current == null) {
      throw const RecordFailure(
        'Current version is unavailable. Refresh history.',
      );
    }
    final parsed = RecordSummary.fromData(head['recordId'] as String, current);
    if (parsed.root != record.root ||
        parsed.patientId != record.patientId ||
        parsed.authorId != record.authorId ||
        parsed.clinicId != record.clinicId ||
        parsed.encounterId != record.encounterId ||
        parsed.encounterType != record.encounterType ||
        parsed.revision != head['revision'] ||
        parsed.visitAt != record.visitAt ||
        parsed.type != record.type ||
        parsed.patientVisible != record.patientVisible) {
      throw const RecordFailure(
        'Current version does not match this record chain.',
      );
    }
    return parsed;
  }

  @override
  Future<Map<String, String>> attribution(RecordSummary record) async {
    final data =
        (await db
                .doc('record_attribution/${record.id}')
                .get(const GetOptions(source: Source.server)))
            .data();
    return {
      if (data?['clinicName'] is String)
        'clinic': data!['clinicName'] as String,
      if (data?['providerName'] is String)
        'provider': data!['providerName'] as String,
    };
  }

  @override
  Future<MedicalRecord> getRecord(String id) async {
    final scope = ClinicalReadScope();
    if (!_validId(id)) throw const FormatException('Invalid record');
    final result = await db
        .doc('medical_records/$id')
        .get(const GetOptions(source: Source.server));
    final data = result.data();
    scope.check();
    if (data == null || data['content'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid record');
    }
    String? internal;
    if (auth.currentUser?.uid == data['authorId']) {
      final note = await db
          .doc('internal_record_notes/$id')
          .get(const GetOptions(source: Source.server));
      final raw = note.data()?['notes'];
      internal = raw is Map
          ? (await ClinicalCrypto.read(
                  Map<String, dynamic>.from(raw),
                  'internal-note',
                  id,
                  data,
                ))['notes']
                as String?
          : raw as String?;
    }
    final content = validateClinicalContent(
      await ClinicalCrypto.read(
        data['content'] as Map<String, dynamic>,
        'record',
        id,
        data,
      ),
    );
    scope.check();
    if (internal != null && internal.length > 5000) {
      throw const FormatException('Invalid internal note');
    }
    return MedicalRecord(
      RecordSummary.fromData(id, data),
      content,
      internalNotes: internal,
    );
  }

  @override
  Future<String?> clinicName(String clinicId) async {
    if (!_validId(clinicId)) return null;
    final data =
        (await db
                .doc('clinic_directory/$clinicId')
                .get(const GetOptions(source: Source.server)))
            .data();
    return data?['status'] == 'active' && data?['displayName'] is String
        ? data!['displayName'] as String
        : null;
  }

  @override
  Future<String?> providerName(String providerId) async {
    if (!_validId(providerId)) return null;
    final data =
        (await db
                .doc('provider_directory/$providerId')
                .get(const GetOptions(source: Source.server)))
            .data();
    return data?['status'] == 'active' && data?['displayName'] is String
        ? data!['displayName'] as String
        : null;
  }

  @override
  Future<void> createFinal(RecordDraft draft) => _create(draft);

  @override
  Future<void> correct(RecordSummary previous, RecordDraft draft) async {
    if (previous.authorId != auth.currentUser?.uid ||
        previous.clinicId != draft.clinicId ||
        previous.patientId != draft.patientId ||
        previous.encounterId != draft.encounterId ||
        previous.encounterType != draft.encounterType ||
        previous.patientVisible != draft.patientVisible ||
        previous.type != draft.type ||
        draft.correctionReason.trim().isEmpty) {
      throw StateError(
        'Only the original author may append a correction in the same active clinical context. Visibility and record identity cannot change.',
      );
    }
    await _create(draft, previous: previous);
  }

  Future<void> _create(RecordDraft draft, {RecordSummary? previous}) async {
    final scope = ClinicalReadScope();
    draft.validate(correction: previous != null);
    final author = auth.currentUser?.uid;
    if (author == null ||
        !_validId(draft.clinicId) ||
        !_validId(draft.patientId) ||
        !_validId(draft.encounterId) ||
        !['appointment', 'referral'].contains(draft.encounterType) ||
        !['visit', 'follow_up'].contains(draft.type) ||
        (draft.operationId != null && !_validId(draft.operationId!))) {
      throw const FormatException('Invalid record input');
    }
    final id = draft.operationId ?? db.collection('medical_records').doc().id;
    final root = previous?.rootRecordId ?? previous?.id ?? id;
    bool acknowledges(Map<String, dynamic>? data) =>
        data != null &&
        data['authorId'] == author &&
        data['patientId'] == draft.patientId &&
        data['encounterId'] == draft.encounterId &&
        data['encounterType'] == draft.encounterType &&
        data['clinicId'] == draft.clinicId &&
        data['recordType'] == draft.type &&
        data['patientVisible'] == draft.patientVisible &&
        (data['rootRecordId'] ?? id) == root &&
        data['supersedesId'] == previous?.id &&
        data['revision'] == (previous?.revision ?? 0) + 1;
    Future<Map<String, dynamic>?> outcome() async =>
        (await db
                .doc('record_summaries/$id')
                .get(const GetOptions(source: Source.server)))
            .data();
    // An exact summary read rechecks consent before retry acknowledgement.
    final existing =
        (await db
                .doc('record_summaries/$id')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (existing != null) {
      if (acknowledges(existing)) {
        return;
      }
      throw const RecordFailure(
        'Save identifier conflicts. Close and reopen the editor.',
      );
    }
    DateTime visit;
    if (previous != null) {
      // Preserve even a historical date whose provenance is unknown.
      visit = previous.visitAt;
      final current = await currentVersion(previous);
      if (current.id != previous.id) {
        // Read after observing the advanced head: a pending stale operation can
        // no longer commit, and an already committed own operation is acknowledged.
        if (acknowledges(await outcome())) return;
        throw const RecordFailure(
          'A newer correction exists. Your proposed text is retained. Review the current version before finalising another correction.',
          operationRejected: true,
        );
      }
    } else {
      final source =
          (await db
                  .doc(
                    draft.encounterType == 'appointment'
                        ? 'appointments/${draft.encounterId}'
                        : 'specialist_appointments/${draft.encounterId}',
                  )
                  .get(const GetOptions(source: Source.server)))
              .data();
      if (source?['startAt'] is! Timestamp) {
        throw const RecordFailure(
          'The encounter visit date is unavailable. Refresh the encounter or request a reviewed correction; no date has been invented.',
        );
      }
      visit = (source!['startAt'] as Timestamp).toDate();
    }
    final now = FieldValue.serverTimestamp();
    final summary = <String, dynamic>{
      'recordId': id,
      'clinicId': draft.clinicId,
      'patientId': draft.patientId,
      'authorId': author,
      'encounterType': draft.encounterType,
      'encounterId': draft.encounterId,
      'status': 'final',
      'recordType': draft.type,
      'patientVisible': draft.patientVisible,
      'revision': (previous?.revision ?? 0) + 1,
      'rootRecordId': root,
      if (previous != null) 'supersedesId': previous.id,
      'visitAt': Timestamp.fromDate(visit),
      'dateSource':
          previous?.dateSource ??
          (previous == null ? 'encounter' : 'legacy-preserved'),
      'createdAt': now,
      'updatedAt': now,
    };
    List<String> item(String text) => text.trim().isEmpty ? [] : [text.trim()];
    final content = <String, dynamic>{
      'notes': draft.notes.trim(),
      'diagnoses': draft.preservedItems['diagnoses'] ?? item(draft.diagnosis),
      'prescriptions':
          draft.preservedItems['prescriptions'] ?? item(draft.prescription),
      'medications':
          draft.preservedItems['medications'] ?? item(draft.medication),
      'labResultMetadata':
          draft.preservedItems['labResultMetadata'] ?? item(draft.labResult),
      'documentRefs': <String>[],
      if (previous != null) 'correctionReason': draft.correctionReason.trim(),
    };
    final record = {
      ...summary,
      'content': await ClinicalCrypto.write(content, 'record', id, summary, {
        author,
        if (draft.patientVisible) draft.patientId,
      }),
    };
    final head = {
      'rootRecordId': root,
      'recordId': id,
      'revision': summary['revision'],
      'updatedAt': now,
    };
    Map<String, dynamic>? internal;
    if (draft.internalNotes.trim().isNotEmpty) {
      internal = {
        ...summary,
        'notes': await ClinicalCrypto.write(
          {'notes': draft.internalNotes.trim()},
          'internal-note',
          id,
          summary,
          {author},
        ),
      };
    }
    // Attribution is a minimal immutable directory snapshot, never client claims.
    final attribution = <String, dynamic>{'recordId': id};
    final priorNames = previous == null
        ? <String, String>{}
        : await this.attribution(previous);
    for (final entry in [('clinic', draft.clinicId), ('provider', author)]) {
      try {
        final name = entry.$1 == 'clinic'
            ? await clinicName(entry.$2)
            : await providerName(entry.$2);
        if (name != null) attribution['${entry.$1}Name'] = name;
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
      }
      if (!attribution.containsKey('${entry.$1}Name') &&
          priorNames[entry.$1] != null) {
        attribution['${entry.$1}Name'] = priorNames[entry.$1];
      }
    }
    try {
      await runServerTransaction(db, author, (tx) async {
        scope.check();
        final saved = (await tx.get(db.doc('record_summaries/$id'))).data();
        scope.check();
        if (saved != null) {
          if (!acknowledges(saved)) {
            throw const RecordFailure(
              'Save identifier conflicts. Close and reopen the editor.',
            );
          }
          return; // Same operation acknowledged after a lost reply.
        }
        // The atomic head update Rule compares the stored revision and preceding
        // ID. A stale/forked write cannot commit, without an extra client head read.
        tx.set(db.doc('medical_records/$id'), record);
        tx.set(db.doc('record_summaries/$id'), summary);
        tx.set(db.doc('record_heads/$root'), head);
        if (internal != null) {
          tx.set(db.doc('internal_record_notes/$id'), internal);
        }
        tx.set(db.doc('record_attribution/$id'), attribution);
      });
    } on FirebaseException {
      if (previous != null) {
        try {
          final latest = await currentVersion(previous);
          final saved = await outcome();
          if (acknowledges(saved)) return;
          if (saved == null && latest.id != previous.id) {
            throw const RecordFailure(
              'A newer correction exists. Proposed text is retained. Review the current version before retrying.',
              operationRejected: true,
            );
          }
        } on FirebaseException {
          // Preserve the original failure when current authority/outcome cannot
          // be established. The same submitted operation remains retryable.
        }
      }
      rethrow;
    }
  }
}

bool _validId(String value) => RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(value);
