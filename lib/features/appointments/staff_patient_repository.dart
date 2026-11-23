import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../shared/data/server_transaction.dart';

/// A clinic operational reference, never an Auth UID or clinical consent.
class StaffPatient {
  const StaffPatient(this.id, this.reference, this.label);
  final String id, reference, label;
}

String staffPatientId(String clinic, String reference) {
  final canonical = reference.trim().toUpperCase();
  if (!RegExp(r'^[A-Z0-9]{4,16}$').hasMatch(canonical)) {
    throw const FormatException(
      'Use a clinic reference of 4–16 letters/digits.',
    );
  }
  return 'guest-$clinic-$canonical';
}

class StaffPatientRepository {
  const StaffPatientRepository(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;

  Future<StaffPatient?> find(String clinic, String reference) async {
    final id = staffPatientId(clinic, reference);
    final row = await db
        .doc('staff_patients/$clinic/patients/$id')
        .get(const GetOptions(source: Source.server));
    final data = row.data();
    return data == null
        ? null
        : StaffPatient(
            id,
            data['reference'] as String,
            data['label'] as String,
          );
  }

  Future<List<StaffPatient>> list(String clinic) async {
    final result = await db
        .collection('staff_patients/$clinic/patients')
        .limit(50)
        .get(const GetOptions(source: Source.server));
    return result.docs
        .map(
          (d) => StaffPatient(
            d.id,
            d.data()['reference'] as String,
            d.data()['label'] as String,
          ),
        )
        .toList();
  }

  Future<String> register(String clinic, String reference, String label) async {
    final id = staffPatientId(clinic, reference);
    if (label.trim().length < 2 || label.trim().length > 80) {
      throw const FormatException(
        'Enter a fictional label of 2–80 characters.',
      );
    }
    final uid =
        auth.currentUser?.uid ?? (throw StateError('Sign in required.'));
    final ref = db.doc('staff_patients/$clinic/patients/$id');
    await runServerTransaction(db, uid, (tx) async {
      final existing = await tx.get(ref);
      if (existing.exists) {
        throw StateError(
          'Reference already exists. Select that identity; do not create a duplicate.',
        );
      }
      tx.set(ref, {
        'patientId': id,
        'clinicId': clinic,
        'reference': reference.trim().toUpperCase(),
        'label': label.trim(),
        'status': 'active',
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
    return id;
  }
}
