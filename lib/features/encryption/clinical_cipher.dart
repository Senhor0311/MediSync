import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Versioned, context-bound primitives. No Firebase dependency or shared secret.
class ClinicalCipher {
  static final aes = AesGcm.with256bits();
  static final x = X25519();
  static final ed = Ed25519();
  static final random = Random.secure();
  static List<int> bytes(int n) => List.generate(n, (_) => random.nextInt(256));
  static String b64(List<int> b) => base64UrlEncode(b);
  static List<int> un64(String s) => base64Url.decode(s);
  static Object? _sort(Object? value) => value is Map
      ? {
          for (final k in value.keys.map((k) => k.toString()).toList()..sort())
            k: _sort(value[k]),
        }
      : value is List
      ? value.map(_sort).toList()
      : value;
  static List<int> canonical(Object? value) =>
      utf8.encode(jsonEncode(_sort(value)));
  static Future<Map<String, dynamic>> seal(
    List<int> clear,
    SecretKey key,
    Object context,
  ) async {
    final box = await aes.encrypt(
      clear,
      secretKey: key,
      nonce: aes.newNonce(),
      aad: canonical(context),
    );
    return {
      'v': 1,
      'alg': 'A256GCM',
      'nonce': b64(box.nonce),
      'ct': b64(box.cipherText),
      'tag': b64(box.mac.bytes),
    };
  }

  static Future<List<int>> open(
    Map<String, dynamic> box,
    SecretKey key,
    Object context,
  ) {
    if (box['v'] != 1 || box['alg'] != 'A256GCM') {
      throw const FormatException('Unsupported encryption version');
    }
    return aes.decrypt(
      SecretBox(
        un64(box['ct'] as String),
        nonce: un64(box['nonce'] as String),
        mac: Mac(un64(box['tag'] as String)),
      ),
      secretKey: key,
      aad: canonical(context),
    );
  }

  static Future<Map<String, dynamic>> bundle(
    String uid,
    int version,
    List<int> identitySeed,
    List<int> encryptionSeed,
  ) async {
    final identity = await ed.newKeyPairFromSeed(identitySeed);
    final encryption = await x.newKeyPairFromSeed(encryptionSeed);
    final data = <String, dynamic>{
      'uid': uid,
      'version': version,
      'identity': b64((await identity.extractPublicKey()).bytes),
      'publicKey': b64((await encryption.extractPublicKey()).bytes),
    };
    return {
      ...data,
      'signature': b64(
        (await ed.sign(canonical(data), keyPair: identity)).bytes,
      ),
    };
  }

  static Future<void> verifyBundle(
    Map<String, dynamic> bundle,
    String identity,
    String uid,
    int version,
  ) async {
    final data = Map<String, dynamic>.from(bundle)..remove('signature');
    if (data['uid'] != uid ||
        data['version'] != version ||
        data['identity'] != identity ||
        !await ed.verify(
          canonical(data),
          signature: Signature(
            un64(bundle['signature'] as String),
            publicKey: SimplePublicKey(
              un64(identity),
              type: KeyPairType.ed25519,
            ),
          ),
        )) {
      throw StateError('Recipient encryption identity could not be verified.');
    }
  }

  static Future<SecretKey> _wrapKey(
    KeyPair privateKey,
    List<int> public,
    List<int> salt,
    Object info,
  ) async {
    final shared = await x.sharedSecretKey(
      keyPair: privateKey,
      remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519),
    );
    return Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, nonce: salt, info: canonical(info));
  }

  static Future<Map<String, dynamic>> encrypt(
    Map<String, dynamic> clear,
    Map<String, dynamic> context,
    Map<String, Map<String, dynamic>> recipients,
  ) async {
    if (recipients.isEmpty || recipients.length > 3) {
      throw ArgumentError('Invalid recipients');
    }
    final key = await aes.newSecretKey();
    final payload = await seal(canonical(clear), key, context);
    final hash = b64((await Sha256().hash(canonical(payload))).bytes);
    final envelopes = <String, dynamic>{};
    for (final entry in recipients.entries) {
      final ephemeral = await x.newKeyPair();
      final salt = bytes(16);
      final info = {
        'context': context,
        'hash': hash,
        'uid': entry.key,
        'version': entry.value['version'],
      };
      final wrapping = await _wrapKey(
        ephemeral,
        un64(entry.value['publicKey'] as String),
        salt,
        info,
      );
      final wrapped = await seal(await key.extractBytes(), wrapping, info);
      envelopes[entry.key] =
          '${(entry.value['version'] as int).toString().padLeft(2, '0')}${
          // Fixed 108-byte envelope: public32 | salt16 | nonce12 | key32 | tag16.
          b64([...(await ephemeral.extractPublicKey()).bytes, ...salt, ...un64(wrapped['nonce'] as String), ...un64(wrapped['ct'] as String), ...un64(wrapped['tag'] as String)])}';
    }
    return {
      'format': 'medisync-clinical-v1',
      'payload': payload,
      'envelopes': envelopes,
    };
  }

  static Future<Map<String, dynamic>> decrypt(
    Map<String, dynamic> encrypted,
    Map<String, dynamic> context,
    String uid,
    Map<int, List<int>> seeds,
  ) async {
    final key = await _unwrap(encrypted, context, uid, seeds);
    return Map<String, dynamic>.from(
      jsonDecode(
        utf8.decode(
          await open(
            Map<String, dynamic>.from(encrypted['payload'] as Map),
            key,
            context,
          ),
        ),
      ) as Map,
    );
  }

  static Future<SecretKey> _unwrap(
    Map<String, dynamic> encrypted,
    Map<String, dynamic> context,
    String uid,
    Map<int, List<int>> seeds,
  ) async {
    if (encrypted['format'] != 'medisync-clinical-v1') {
      throw const FormatException('Unsupported clinical ciphertext');
    }
    final envelope =
        (encrypted['envelopes'] as Map)[uid] as String? ??
        (throw StateError('No encryption grant for this account.'));
    if (!RegExp(r'^(0[1-9]|1[0-9]|20)[A-Za-z0-9_-]{144}$').hasMatch(envelope)) {
      throw const FormatException('Invalid envelope version or encoding');
    }
    final version = int.parse(envelope.substring(0, 2));
    final wrapped = un64(envelope.substring(2));
    if (wrapped.length != 108) {
      throw const FormatException('Invalid key envelope');
    }
    final seed =
        seeds[version] ??
        (throw StateError(
          'This key version is missing from the recovery vault.',
        ));
    final payload = Map<String, dynamic>.from(encrypted['payload'] as Map);
    final info = {
      'context': context,
      'hash': b64((await Sha256().hash(canonical(payload))).bytes),
      'uid': uid,
      'version': version,
    };
    final wrapping = await _wrapKey(
      await x.newKeyPairFromSeed(seed),
      wrapped.sublist(0, 32),
      wrapped.sublist(32, 48),
      info,
    );
    final key = SecretKey(
      await aes.decrypt(
        SecretBox(
          wrapped.sublist(60, 92),
          nonce: wrapped.sublist(48, 60),
          mac: Mac(wrapped.sublist(92, 108)),
        ),
        secretKey: wrapping,
        aad: canonical(info),
      ),
    );
    return key;
  }

  /// Preserve the immutable original ciphertext, wrapping its key for one named recipient.
  static Future<Map<String, dynamic>> regrant(
    Map<String, dynamic> encrypted,
    Map<String, dynamic> context,
    String owner,
    Map<int, List<int>> seeds,
    String recipient,
    Map<String, dynamic> bundle,
  ) async {
    final key = await _unwrap(encrypted, context, owner, seeds);
    // Authenticate the original payload before granting it, without changing it.
    await open(
      Map<String, dynamic>.from(encrypted['payload'] as Map),
      key,
      context,
    );
    final ephemeral = await x.newKeyPair(), salt = bytes(16);
    final info = {
      'context': context,
      'hash': b64((await Sha256().hash(canonical(encrypted['payload']))).bytes),
      'uid': recipient,
      'version': bundle['version'],
    };
    final wrapping = await _wrapKey(
      ephemeral,
      un64(bundle['publicKey'] as String),
      salt,
      info,
    );
    final wrapped = await seal(await key.extractBytes(), wrapping, info);
    final envelope =
        '${(bundle['version'] as int).toString().padLeft(2, '0')}${b64([...(await ephemeral.extractPublicKey()).bytes, ...salt, ...un64(wrapped['nonce'] as String), ...un64(wrapped['ct'] as String), ...un64(wrapped['tag'] as String)])}';
    return {
      'format': 'medisync-clinical-v1',
      'payload': encrypted['payload'],
      'envelopes': {recipient: envelope},
    };
  }
}
