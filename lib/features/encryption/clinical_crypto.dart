import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

import 'clinical_cipher.dart';

class ClinicalCryptoFailure implements Exception {
  const ClinicalCryptoFailure(this.message);
  final String message;
}

class ClinicalCrypto extends ChangeNotifier {
  ClinicalCrypto(this.db, this.auth) {
    _authSubscription = auth.authStateChanges().listen((user) {
      if (user?.uid != unlockedUid) lock();
    });
  }
  static ClinicalCrypto? instance;
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  late final StreamSubscription<User?> _authSubscription;
  @override
  void dispose() {
    _authSubscription.cancel();
    lock();
    super.dispose();
  }

  String? unlockedUid;
  List<int>? _identity;
  Map<int, List<int>> _keys = {};
  String? _code;
  int _version = 0, _revision = 0, _epoch = 0;
  int _generation = 0;
  int get generation => _generation;
  bool isCurrent(int generation) => generation == _generation && unlocked;
  void _check(int generation, String subject, {bool requireUnlocked = true}) {
    if (generation != _generation ||
        auth.currentUser?.uid != subject ||
        requireUnlocked && !unlocked) {
      throw const ClinicalCryptoFailure(
        'Encryption session changed. Unlock again and check history before retrying a save whose result was not confirmed.',
      );
    }
  }

  bool get unlocked =>
      unlockedUid != null && unlockedUid == auth.currentUser?.uid;
  String get uid =>
      auth.currentUser?.uid ?? (throw StateError('Sign in required'));
  void lock() {
    _generation++;
    unlockedUid = null;
    _identity = null;
    _keys = {};
    _code = null;
    notifyListeners();
  }

  static String newCode() => ClinicalCipher.b64(ClinicalCipher.bytes(32));
  Future<bool> enrolled() async =>
      (await db
              .doc('crypto_profiles/$uid')
              .get(const GetOptions(source: Source.server)))
          .exists;
  Object _vaultContext(int revision, int epoch) => {
    'kind': 'private-vault',
    'uid': uid,
    'revision': revision,
    'epoch': epoch,
  };
  Future<Map<String, dynamic>> _vault(
    String code,
    int revision,
    int epoch,
    List<int> identity,
    Map<int, List<int>> keys,
  ) => ClinicalCipher.seal(
    ClinicalCipher.canonical({
      'identity': ClinicalCipher.b64(identity),
      'keys': {
        for (final e in keys.entries) '${e.key}': ClinicalCipher.b64(e.value),
      },
    }),
    SecretKey(ClinicalCipher.un64(code)),
    _vaultContext(revision, epoch),
  );
  Future<void> enrol(String code) async {
    final subject = uid;
    final generation = _generation;
    // Refuse cached/offline setup before preparing a write that could be queued.
    await db
        .doc('crypto_profiles/$subject')
        .get(const GetOptions(source: Source.server));
    if (ClinicalCipher.un64(code).length != 32) {
      throw const FormatException('Invalid recovery code');
    }
    final identity = ClinicalCipher.bytes(32), seed = ClinicalCipher.bytes(32);
    final bundle = await ClinicalCipher.bundle(uid, 1, identity, seed);
    final vault = await _vault(code, 1, 1, identity, {1: seed});
    final batch = db.batch();
    _check(generation, subject, requireUnlocked: false);
    batch.set(db.doc('crypto_profiles/$uid'), {
      'uid': uid,
      'identity': bundle['identity'],
      'version': 1,
      'revision': 1,
      'epoch': 1,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(db.doc('crypto_key_versions/$uid-v1'), bundle);
    batch.set(db.doc('crypto_vaults/$uid'), {
      'uid': uid,
      'revision': 1,
      'epoch': 1,
      'box': vault,
    });
    await batch.commit();
    _check(generation, subject, requireUnlocked: false);
    await unlock(code);
  }

  Future<void> unlock(String code) async {
    final currentUid = uid;
    final generation = _generation;
    if (ClinicalCipher.un64(code.trim()).length != 32) {
      throw const FormatException('Invalid recovery code');
    }
    final profile =
        (await db
                .doc('crypto_profiles/$currentUid')
                .get(const GetOptions(source: Source.server)))
            .data();
    final vault =
        (await db
                .doc('crypto_vaults/$currentUid')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (profile == null ||
        vault == null ||
        profile['revision'] != vault['revision'] ||
        profile['epoch'] != vault['epoch']) {
      throw StateError('Encryption vault unavailable. Retry online.');
    }
    final clear = jsonDecode(
      utf8.decode(
        await ClinicalCipher.open(
          Map<String, dynamic>.from(vault['box'] as Map),
          SecretKey(ClinicalCipher.un64(code.trim())),
          _vaultContext(vault['revision'] as int, vault['epoch'] as int),
        ),
      ),
    ) as Map;
    final keys = {
      for (final e in (clear['keys'] as Map).entries)
        int.parse(e.key as String): ClinicalCipher.un64(e.value as String),
    };
    final identity = ClinicalCipher.un64(clear['identity'] as String);
    final version = profile['version'] as int;
    final expected = await ClinicalCipher.bundle(
      currentUid,
      version,
      identity,
      keys[version]!,
    );
    final published =
        (await db
                .doc('crypto_key_versions/$currentUid-v$version')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (expected['identity'] != profile['identity'] ||
        jsonEncode(expected) != jsonEncode(published) &&
            (published == null ||
                expected.entries.any((e) => published[e.key] != e.value))) {
      throw StateError('Vault does not match the published identity.');
    }
    _check(generation, currentUid, requireUnlocked: false);
    unlockedUid = uid;
    _keys = keys;
    _identity = identity;
    _code = code.trim();
    _version = version;
    _revision = vault['revision'] as int;
    _epoch = vault['epoch'] as int;
    notifyListeners();
  }

  Future<void> rotate({String? replacementCode}) async {
    if (!unlocked) throw StateError('Unlock encryption first');
    final subject = uid, generation = _generation;
    final expectedRevision = _revision;
    await db
        .doc('crypto_profiles/$uid')
        .get(const GetOptions(source: Source.server));
    if (_version >= 20 && replacementCode == null) {
      throw StateError(
        'Key history limit reached. Contact support before further rotation.',
      );
    }
    final version = _version + (replacementCode == null ? 1 : 0);
    final revision = _revision + 1,
        epoch = _epoch + (replacementCode == null ? 0 : 1);
    final keys = {
      ..._keys,
      if (replacementCode == null) version: ClinicalCipher.bytes(32),
    };
    final code = replacementCode ?? _code!;
    if (ClinicalCipher.un64(code).length != 32) {
      throw const FormatException('Invalid replacement code');
    }
    final vault = await _vault(code, revision, epoch, _identity!, keys);
    final bundle = await ClinicalCipher.bundle(
      uid,
      version,
      _identity!,
      keys[version]!,
    );
    await db.runTransaction((tx) async {
      _check(generation, subject);
      final ref = db.doc('crypto_profiles/$uid');
      final old = (await tx.get(ref)).data();
      _check(generation, subject);
      if (old?['revision'] != expectedRevision) {
        lock();
        throw StateError(
          'Vault changed on another device. Lock and unlock with the current recovery code.',
        );
      }
      tx.update(ref, {
        'version': version,
        'revision': revision,
        'epoch': epoch,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(db.doc('crypto_vaults/$uid'), {
        'uid': uid,
        'revision': revision,
        'epoch': epoch,
        'box': vault,
      });
      if (replacementCode == null) {
        tx.set(db.doc('crypto_key_versions/$uid-v$version'), bundle);
      }
    });
    _check(generation, subject);
    await unlock(code);
  }

  Future<Map<String, dynamic>> encrypt(
    Map<String, dynamic> clear,
    Map<String, dynamic> context,
    Set<String> recipients,
  ) async {
    if (!unlocked) {
      throw const ClinicalCryptoFailure(
        'Unlock encryption before writing clinical information.',
      );
    }
    final subject = uid, generation = _generation;
    final own =
        (await db
                .doc('crypto_profiles/$uid')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (own == null) {
      throw const ClinicalCryptoFailure(
        'Encryption setup is missing. Complete setup and back up your recovery code in Settings before saving.',
      );
    }
    if (own['revision'] != _revision || own['epoch'] != _epoch) {
      lock();
      throw const ClinicalCryptoFailure(
        'Encryption changed on another device. Lock this vault and unlock it using your current recovery code before saving.',
      );
    }
    final bundles = <String, Map<String, dynamic>>{};
    for (final recipient in recipients) {
      final profile =
          (await db
                  .doc('crypto_profiles/$recipient')
                  .get(const GetOptions(source: Source.server)))
              .data();
      if (profile == null) {
        final person = recipient == context['patientId']
            ? 'patient'
            : recipient == context['specialistId']
            ? 'named specialist'
            : 'authorised recipient';
        throw ClinicalCryptoFailure(
          'The $person must sign in and complete encryption setup in Settings before this clinical information can be saved. Ask them to complete setup, then retry.',
        );
      }
      final version = profile['version'] as int;
      final bundle =
          (await db
                  .doc('crypto_key_versions/$recipient-v$version')
                  .get(const GetOptions(source: Source.server)))
              .data();
      if (bundle == null) {
        throw const ClinicalCryptoFailure(
          'Recipient key unavailable. Retry after they finish encryption setup.',
        );
      }
      await ClinicalCipher.verifyBundle(
        bundle,
        profile['identity'] as String,
        recipient,
        version,
      );
      bundles[recipient] = bundle;
    }
    _check(generation, subject);
    final encrypted = await ClinicalCipher.encrypt(clear, context, bundles);
    _check(generation, subject);
    return encrypted;
  }

  Future<Map<String, dynamic>> decrypt(
    Map<String, dynamic> box,
    Map<String, dynamic> context,
  ) async {
    if (!unlocked) {
      throw const ClinicalCryptoFailure(
        'Your encryption vault is locked. Unlock it with your recovery code in Settings, then retry.',
      );
    }
    final subject = uid, generation = _generation;
    final result = await ClinicalCipher.decrypt(box, context, subject, _keys);
    try {
      _check(generation, subject);
    } catch (_) {
      result.clear();
      rethrow;
    }
    return result;
  }

  Future<Map<String, dynamic>> grantRecipient(
    Map<String, dynamic> box,
    Map<String, dynamic> context,
    String recipient,
  ) async {
    if (!unlocked) {
      throw const ClinicalCryptoFailure(
        'Unlock encryption before sharing a record.',
      );
    }
    final subject = uid, generation = _generation;
    final own =
        (await db
                .doc('crypto_profiles/$uid')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (own?['revision'] != _revision) {
      lock();
      throw const ClinicalCryptoFailure(
        'Your vault changed on another device. Lock and unlock it again before sharing.',
      );
    }
    final profile =
        (await db
                .doc('crypto_profiles/$recipient')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (profile == null) {
      throw const ClinicalCryptoFailure(
        'The specialist must enrol encryption before you can share a record.',
      );
    }
    final version = profile['version'] as int;
    final bundle =
        (await db
                .doc('crypto_key_versions/$recipient-v$version')
                .get(const GetOptions(source: Source.server)))
            .data();
    if (bundle == null) {
      throw const ClinicalCryptoFailure(
        'Specialist encryption key is unavailable.',
      );
    }
    await ClinicalCipher.verifyBundle(
      bundle,
      profile['identity'] as String,
      recipient,
      version,
    );
    _check(generation, subject);
    final result = await ClinicalCipher.regrant(
      box,
      context,
      subject,
      _keys,
      recipient,
      bundle,
    );
    _check(generation, subject);
    return result;
  }

  static Map<String, dynamic> context(
    String kind,
    String id,
    Map<String, dynamic> data,
  ) => {
    'kind': kind,
    'id': id,
    for (final k in [
      'clinicId',
      'patientId',
      'authorId',
      'providerId',
      'encounterType',
      'encounterId',
      'revision',
      'referringDoctorId',
      'specialistId',
      'sourceAppointmentId',
      'destinationClinicId',
    ])
      if (data.containsKey(k)) k: data[k],
  };
  static Future<Map<String, dynamic>> read(
    Map<String, dynamic> value,
    String kind,
    String id,
    Map<String, dynamic> data,
  ) async => value['format'] == 'medisync-clinical-v1'
      ? (instance ?? (throw StateError('Encryption unavailable'))).decrypt(
          value,
          context(kind, id, data),
        )
      : {...value, 'legacyPlaintext': true};
  static Future<Map<String, dynamic>> write(
    Map<String, dynamic> clear,
    String kind,
    String id,
    Map<String, dynamic> data,
    Set<String> recipients,
  ) =>
      (instance ??
              (throw const ClinicalCryptoFailure(
                'Encryption is unavailable. Complete encryption setup and unlock your vault before saving.',
              )))
          .encrypt(clear, context(kind, id, data), recipients);
}
