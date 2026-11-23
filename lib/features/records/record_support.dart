import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../shared/data/history_page.dart';

/// Full-precision timestamp and document ID: equal visit times cannot skip rows.
Future<HistoryPage<T>> readRecordPage<T>(
  Query<Map<String, dynamic>> query,
  T Function(String, Map<String, dynamic>) parse, {
  String? after,
}) async {
  var page = query
      .orderBy('visitAt', descending: true)
      .orderBy(FieldPath.documentId, descending: true)
      .limit(20);
  if (after != null) {
    final cursor = jsonDecode(after);
    page = page.startAfter(
      cursor is List
          ? [Timestamp(cursor[0] as int, cursor[1] as int), cursor[2]]
          : [_decodeCursor(cursor['value'], query.firestore), cursor['id']],
    );
  }
  final result = await page.get(const GetOptions(source: Source.server));
  final last = result.docs.isEmpty ? null : result.docs.last;
  return parseRecordRows(
    result.docs.map((d) => MapEntry(d.id, d.data())),
    parse,
    result.size == 20
        ? jsonEncode({
            'value': _encodeCursor(last!.data()['visitAt']),
            'id': last.id,
          })
        : null,
  );
}

HistoryPage<T> parseRecordRows<T>(
  Iterable<MapEntry<String, Map<String, dynamic>>> rows,
  T Function(String, Map<String, dynamic>) parse,
  String? next,
) {
  final items = <T>[], unavailable = <String, String>{};
  for (final row in rows) {
    try {
      items.add(parse(row.key, row.value));
    } on FormatException {
      unavailable[row.key] = 'Historical metadata is invalid; this version is unavailable. Request reviewed access.';
    } on TypeError {
      unavailable[row.key] = 'Historical metadata has invalid field types; this version is unavailable.';
    }
  }
  return HistoryPage(items, next, unavailable: unavailable);
}

Object? _encodeCursor(Object? value) => switch (value) {
  double n when !n.isFinite => {
    't': 'number',
    'v': n.isNaN
        ? 'nan'
        : n.isNegative
        ? '-infinity'
        : 'infinity',
  },
  Timestamp t => {'t': 'timestamp', 's': t.seconds, 'n': t.nanoseconds},
  DocumentReference r => {'t': 'reference', 'p': r.path},
  GeoPoint p => {'t': 'geo', 'a': p.latitude, 'o': p.longitude},
  Uint8List b => {'t': 'bytes', 'b': base64Encode(b)},
  Map m => {'t': 'map', 'v': m.map((k, v) => MapEntry(k, _encodeCursor(v)))},
  List l => {'t': 'list', 'v': l.map(_encodeCursor).toList()},
  _ => value,
};
Object? _decodeCursor(dynamic value, FirebaseFirestore db) {
  if (value is! Map) return value;
  return switch (value['t']) {
    'number' =>
      value['v'] == 'nan'
          ? double.nan
          : value['v'] == '-infinity'
          ? double.negativeInfinity
          : double.infinity,
    'timestamp' => Timestamp(value['s'] as int, value['n'] as int),
    'reference' => db.doc(value['p'] as String),
    'geo' => GeoPoint(
      (value['a'] as num).toDouble(),
      (value['o'] as num).toDouble(),
    ),
    'bytes' => base64Decode(value['b'] as String),
    'map' => (value['v'] as Map).map(
      (k, v) => MapEntry(k, _decodeCursor(v, db)),
    ),
    'list' => (value['v'] as List).map((v) => _decodeCursor(v, db)).toList(),
    _ => throw const FormatException('Invalid history cursor'),
  };
}

/// Treat authenticated decryption as bytes, not proof of a valid clinical schema.
Map<String, dynamic> validateClinicalContent(Map<String, dynamic> content) {
  const fields = [
    'diagnoses',
    'prescriptions',
    'medications',
    'labResultMetadata',
  ];
  if (content['notes'] is! String ||
      (content['notes'] as String).length > 5000 ||
      content['documentRefs'] is! List ||
      (content['documentRefs'] as List).isNotEmpty ||
      content.keys.any(
        (k) => ![
          'notes',
          ...fields,
          'documentRefs',
          'correctionReason',
          'legacyPlaintext',
        ].contains(k),
      ) ||
      content.containsKey('correctionReason') &&
          (content['correctionReason'] is! String ||
              (content['correctionReason'] as String).length > 200)) {
    throw const FormatException(
      'Clinical content is unavailable: invalid schema',
    );
  }
  for (final field in fields) {
    final value = content[field];
    if (value is! List ||
        value.length > 20 ||
        value.any((item) => item is! String) ||
        value.cast<String>().fold<int>(0, (n, s) => n + s.length) > 2000) {
      throw const FormatException(
        'Clinical content is unavailable: invalid field types or size',
      );
    }
  }
  return content;
}

String recordDate(DateTime? value) {
  if (value == null) return 'Unavailable in historical record';
  final local = value.toLocal(), offset = value.toLocal().timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  return '${local.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} (device local time, UTC${offset.isNegative ? '-' : '+'}${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')})';
}

class RecordFailure implements Exception {
  const RecordFailure(this.message, {this.operationRejected = false});
  final String message;
  // Set only after server reads establish that a stale operation did not commit.
  final bool operationRejected;
}

/// Minimal identity projection, validated against the patient's own profile.
/// This is not a profile directory and grants no care permission.
Future<void> publishEncounterLabel(
  FirebaseFirestore db,
  String patientId,
  String clinicId,
  String type,
  String encounterId,
) async {
  final own =
      (await db
              .doc('users/$patientId')
              .get(const GetOptions(source: Source.server)))
          .data();
  await db.doc('encounter_labels/$type-$encounterId').set({
    'patientId': patientId,
    'clinicId': clinicId,
    'encounterType': type,
    'encounterId': encounterId,
    'displayName': own!['displayName'],
    'updatedAt': FieldValue.serverTimestamp(),
  });
}
