import '../../shared/data/history_page.dart';
import 'own_export.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum PrivacyRequestType { access, correction, deletion }

enum PrivacyRequestStatus {
  pending,
  underReview,
  fulfilled,
  partiallyFulfilled,
  declined,
}

class PrivacyRequest {
  const PrivacyRequest({
    required this.id,
    required this.userId,
    required this.type,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final PrivacyRequestType type;
  final PrivacyRequestStatus status;
  final DateTime createdAt;

  static PrivacyRequest? fromFirestore(String id, Map<String, dynamic> data) {
    if (data['requestId'] != id ||
        data['userId'] is! String ||
        data['createdAt'] is! Timestamp) {
      return null;
    }
    final type = PrivacyRequestType.values.where((t) => t.name == data['type']);
    final status = PrivacyRequestStatus.values.where(
      (s) => switch (s) {
        PrivacyRequestStatus.pending => data['status'] == 'pending',
        PrivacyRequestStatus.underReview => data['status'] == 'under_review',
        PrivacyRequestStatus.fulfilled => data['status'] == 'fulfilled',
        PrivacyRequestStatus.partiallyFulfilled =>
          data['status'] == 'partially_fulfilled',
        PrivacyRequestStatus.declined => data['status'] == 'declined',
      },
    );
    if (type.isEmpty || status.isEmpty) return null;
    return PrivacyRequest(
      id: id,
      userId: data['userId'] as String,
      type: type.first,
      status: status.first,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
    );
  }
}

abstract class PrivacyRepository {
  Future<List<PrivacyRequest>> ownRequests();
  Future<void> submit(PrivacyRequestType type);
  Future<List<PrivacyRequest>> reviewQueue();
  Future<void> startReview(String requestId);
}

class FirestorePrivacyRepository
    implements PrivacyRepository, HistoryPager<PrivacyRequest>, OwnDataExport {
  const FirestorePrivacyRepository(this.db, this.auth);

  final FirebaseFirestore db;
  final FirebaseAuth auth;
  @override
  Future<OwnExportPage> exportPage({Map<String, String> after = const {}}) =>
      exportOwnPage(this, after);

  String get _uid =>
      auth.currentUser?.uid ?? (throw StateError('Sign in required'));

  List<PrivacyRequest> _parse(QuerySnapshot<Map<String, dynamic>> result) {
    final requests = result.docs
        .map((doc) => PrivacyRequest.fromFirestore(doc.id, doc.data()))
        .whereType<PrivacyRequest>()
        .toList();
    requests.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return requests;
  }

  @override
  Future<HistoryPage<PrivacyRequest>> historyPage({
    String? after,
    Map<String, String> scope = const {},
  }) {
    Query<Map<String, dynamic>> query = db.collection('privacy_requests');
    if (scope['review'] != 'true') {
      query = query.where('userId', isEqualTo: _uid);
    }
    return readHistoryPage(
      query,
      (id, data) =>
          PrivacyRequest.fromFirestore(id, data) ??
          (throw const FormatException('Invalid privacy request')),
      after: after,
    );
  }

  @override
  Future<List<PrivacyRequest>> ownRequests() async => _parse(
    await db
        .collection('privacy_requests')
        .where('userId', isEqualTo: _uid)
        .limit(50)
        .get(const GetOptions(source: Source.server)),
  );

  @override
  Future<void> submit(PrivacyRequestType type) async {
    final ref = db.collection('privacy_requests').doc();
    await ref.set({
      'requestId': ref.id,
      'userId': _uid,
      'type': type.name,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<List<PrivacyRequest>> reviewQueue() async => _parse(
    await db
        .collection('privacy_requests')
        .limit(50)
        .get(const GetOptions(source: Source.server)),
  );

  @override
  Future<void> startReview(String requestId) =>
      db.doc('privacy_requests/$requestId').update({
        'status': 'under_review',
        'reviewedBy': _uid,
        'reviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
}
