import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';
import '../records/record_support.dart';
import '../appointments/appointment_repository.dart';
import 'privacy_repository.dart';

class OwnExportPage {
  OwnExportPage(this.json, this.cursors);
  String json;
  final Map<String, String> cursors;
  void clear() => json = '';
}

abstract interface class OwnDataExport {
  Future<OwnExportPage> exportPage({Map<String, String> after = const {}});
}

Future<OwnExportPage> exportOwnPage(
  FirestorePrivacyRepository repo,
  Map<String, String> after,
) async {
  final scope = ClinicalReadScope();
  final uid = repo.auth.currentUser!.uid;
  void check() {
    scope.check();
    if (repo.auth.currentUser?.uid != uid) {
      throw StateError('Export account changed');
    }
  }

  final data = <String, dynamic>{
    'format': 'medisync-own-access-v2',
    'uid': uid,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'scope': 'One bounded page per collection; follow continuation cursors for remaining data. Contains decrypted personal clinical information. Keep this export private. No private keys, author-only notes or other accounts are included.',
  };
  final cursors = <String, String>{};
  final exceptions = <Map<String, String>>[];
  Future<Map<String, dynamic>?> ownDocument(String path) async {
    try {
      final value =
          (await repo.db.doc(path).get(const GetOptions(source: Source.server)))
              .data();
      check();
      return value;
    } catch (_) {
      exceptions.add({
        'collection': path.split('/').first,
        'id': path.split('/').last,
        'cause': 'Document unavailable under current access/connectivity. Retry or request a reviewed operator export.',
      });
      return null;
    }
  }

  data['profile'] = await ownDocument('users/$uid');
  final user = repo.auth.currentUser!;
  data['authentication'] = {
    'uid': uid,
    'email': user.email,
    'emailVerified': user.emailVerified,
    'createdAt': user.metadata.creationTime?.toUtc().toIso8601String(),
    'lastSignInAt': user.metadata.lastSignInTime?.toUtc().toIso8601String(),
  };
  data['careConsent'] = await ownDocument('patient_controls/$uid');
  final publicProfile = await ownDocument('crypto_profiles/$uid');
  data['publicEncryptionProfile'] = publicProfile;
  data['publicKeyVersions'] = [
    if (publicProfile?['version'] is int &&
        (publicProfile!['version'] as int) >= 1 &&
        (publicProfile['version'] as int) <= 20)
      for (
        var version = 1;
        version <= (publicProfile['version'] as int);
        version++
      )
        await ownDocument('crypto_key_versions/$uid-v$version'),
  ];
  data['exclusions'] = {
    'privateKeysAndVault': 'Recovery-wrapped vaults, private seeds, login tokens and recovery secrets are excluded. Preserve your recovery backup separately.',
    'internalNotes': 'Author-only internal clinical notes and other patients’ information require separate lawful review; no blanket entitlement is inferred.',
    'practitionerReferences': 'Records about other patients that name you as a practitioner/booker are not included in self-service export. Request an identity/third-party-reviewed operator export.',
    'careRelationships': 'Historical care grants and queue-observer projections cannot be enumerated by the client. Relevant encounter IDs appear in appointments/referrals; operator review can retrieve permitted omitted metadata.',
    'audit': 'No exhaustive trusted read/denial audit exists. This export cannot supply one.',
    'administrativeStatusEvents': 'The current application status is in your profile. Privileged account-review reasons/events require a reviewed operator export.',
  };
  final collections = <String, Query<Map<String, dynamic>>>{
    for (final name in [
      'medical_records',
      'record_summaries',
      'appointments',
      'specialist_appointments',
      'specialist_appointment_versions',
      'referrals',
      'record_shares',
      'record_share_index',
      'queues',
    ])
      name: repo.db.collection(name).where('patientId', isEqualTo: uid),
    'privacy_requests': repo.db
        .collection('privacy_requests')
        .where('userId', isEqualTo: uid),
    'memberships': repo.db
        .collectionGroup('members')
        .where('userId', isEqualTo: uid),
    'notification_history': repo.db.collection(
      'notification_history/$uid/items',
    ),
  };
  for (final collection in collections.keys) {
    check();
    if (after.isNotEmpty && !after.containsKey(collection)) continue;
    Query<Map<String, dynamic>> query = collections[collection]!;
    if (['medical_records', 'record_summaries'].contains(collection)) {
      query = query.where('patientVisible', isEqualTo: true);
    }
    query = query.orderBy(FieldPath.documentId).limit(20);
    if (after[collection]?.isNotEmpty == true) {
      query = query.startAfter([after[collection]]);
    }
    QuerySnapshot<Map<String, dynamic>> page;
    try {
      page = await query.get(const GetOptions(source: Source.server));
    } catch (_) {
      exceptions.add({
        'collection': collection,
        'cause': 'This collection page is unavailable under current Rules, indexes, connectivity or historical access. Other sections are preserved; request reviewed fulfilment for omissions.',
      });
      // A failed continuation is retained for retry, never silently exhausted.
      cursors[collection] = after[collection] ?? '';
      data[collection] = <Map<String, dynamic>>[];
      continue;
    }
    if (page.docs.length == 20) {
      cursors[collection] = collection == 'memberships'
          ? page.docs.last.reference.path
          : page.docs.last.id;
    }
    final rows = <Map<String, dynamic>>[];
    for (final doc in page.docs) {
      check();
      final row = <String, dynamic>{'id': doc.id, ...doc.data()};
      try {
        if (collection == 'medical_records') {
          // This ID-ordered scan already has the authorised clinical document;
          // do not read it a second time or fetch author-only notes.
          row['content'] = validateClinicalContent(
            await ClinicalCrypto.read(
              Map<String, dynamic>.from(row['content'] as Map),
              'record',
              doc.id,
              row,
            ),
          );
        } else if (collection == 'appointments') {
          try {
            row['reason'] = await FirestoreAppointmentRepository(
              repo.db,
              repo.auth,
            ).visitReason(doc.id);
          } on FirebaseException catch (e) {
            if (e.code != 'permission-denied') rethrow;
            row['reasonUnavailable'] = true;
            exceptions.add({
              'collection': collection,
              'id': doc.id,
              'field': 'reason',
              'cause': 'Current Rules do not permit this historical reason. Request a reviewed operator export; no reason was silently invented.',
            });
          }
        } else if (collection == 'referrals') {
          for (final field in ['reason', 'rejectionReason']) {
            if (row[field] is Map) {
              row[field] = (await ClinicalCrypto.read(
                Map<String, dynamic>.from(row[field] as Map),
                'referral-$field',
                doc.id,
                row,
              ))[field];
            }
          }
        } else if (collection == 'privacy_requests' &&
            row['receiptId'] is String) {
          row['fulfilmentReceipt'] = await ownDocument(
            'privacy_receipts/${row['receiptId']}',
          );
        }
      } catch (_) {
        row['decryptionOrDetailUnavailable'] = true;
        exceptions.add({
          'collection': collection,
          'id': doc.id,
          'cause': 'Encrypted content/detail could not be retrieved or authenticated. No plaintext success is claimed. Unlock with the correct recovery code and retry; otherwise request reviewed access.',
        });
      }
      rows.add(row);
    }
    data[collection] = rows;
  }
  data['continuationCursors'] = cursors;
  data['exportExceptions'] = exceptions;
  Object? safe(Object? value) => value is Timestamp
      ? value.toDate().toUtc().toIso8601String()
      : value is Map
      ? value.map((k, v) => MapEntry(k.toString(), safe(v)))
      : value is List
      ? value.map(safe).toList()
      : value;
  check();
  return OwnExportPage(
    const JsonEncoder.withIndent('  ').convert(safe(data)),
    cursors,
  );
}
