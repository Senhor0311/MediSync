import 'package:cloud_firestore/cloud_firestore.dart';

/// Refuse mutations while the SDK is in an offline/cache-only state.
/// Authorisation and invariants still belong to Rules and the transaction;
/// this preflight is only a connectivity check, never an authority grant.
Future<T> runServerTransaction<T>(
  FirebaseFirestore db,
  String uid,
  Future<T> Function(Transaction) action,
) async {
  await db.doc('users/$uid').get(const GetOptions(source: Source.server));
  return db.runTransaction<T>(action);
}
