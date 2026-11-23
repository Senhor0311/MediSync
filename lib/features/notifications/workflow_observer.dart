import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../auth/auth_models.dart';
import 'notification_repository.dart';

/// Bounded online observations, never an exhaustive server delivery service.
class WorkflowObserver {
  WorkflowObserver(
    this.db,
    this.auth,
    this.uid,
    this.grants, {
    required this.deliver,
  });
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final String uid;
  final List<ClinicGrant> grants;
  final Future<void> Function(String) deliver;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, StreamSubscription<dynamic>> _nested = {};
  bool _active = true;
  bool get active => _active && auth.currentUser?.uid == uid;

  void start() {
    _watch(
      db
          .collection('appointments')
          .where('patientId', isEqualTo: uid)
          .orderBy('updatedAt', descending: true)
          .limit(50),
      'appointment',
      'patient',
      null,
    );
    _watch(
      db
          .collection('specialist_appointments')
          .where('patientId', isEqualTo: uid)
          .orderBy('updatedAt', descending: true)
          .limit(50),
      'specialist',
      'patient',
      null,
    );
    _watch(
      db
          .collection('referrals')
          .where('patientId', isEqualTo: uid)
          .orderBy('updatedAt', descending: true)
          .limit(20),
      'referral',
      'patient',
      null,
    );
    for (final grant in grants.take(5)) {
      if (grant.role == 'specialist') {
        var initial = true;
        _subscriptions.add(
          db
              .collection('referral_inbox')
              .where('clinicId', isEqualTo: grant.clinicId)
              .where('specialistId', isEqualTo: uid)
              .limit(20)
              .snapshots(includeMetadataChanges: true)
              .listen((page) {
                if (!active ||
                    page.metadata.isFromCache ||
                    page.metadata.hasPendingWrites) {
                  return;
                }
                final current = page.docs
                    .map((doc) => 'referral:${grant.clinicId}:${doc.id}')
                    .toSet();
                _removeNested('referral:${grant.clinicId}:', current);
                for (final doc in page.docs) {
                  final key = 'referral:${grant.clinicId}:${doc.id}';
                  if (_nested.containsKey(key)) continue;
                  final notifyFirst = !initial;
                  var first = true;
                  _nested[key] = db
                      .doc('referrals/${doc.id}')
                      .snapshots(includeMetadataChanges: true)
                      .listen((snapshot) {
                        if (!active ||
                            snapshot.metadata.isFromCache ||
                            snapshot.metadata.hasPendingWrites ||
                            !snapshot.exists) {
                          return;
                        }
                        unawaited(
                          _observed(
                            snapshot,
                            'referral',
                            'specialist',
                            grant.clinicId,
                            notifyFirst || !first,
                          ),
                        );
                        first = false;
                      }, onError: (Object _) {});
                }
                initial = false;
              }, onError: (Object _) {}),
        );
        _watch(
          db
              .collection('specialist_appointments')
              .where('clinicId', isEqualTo: grant.clinicId)
              .where('providerId', isEqualTo: uid)
              .orderBy('updatedAt', descending: true)
              .limit(50),
          'specialist',
          'specialist',
          grant.clinicId,
        );
      } else if (grant.role == 'doctor') {
        _subscriptions.add(
          db
              .collection('appointments')
              .where('clinicId', isEqualTo: grant.clinicId)
              .where('providerId', isEqualTo: uid)
              .orderBy('updatedAt', descending: true)
              .limit(50)
              .snapshots(includeMetadataChanges: true)
              .listen((page) {
                if (!active ||
                    page.metadata.isFromCache ||
                    page.metadata.hasPendingWrites) {
                  return;
                }
                final sources = page.docs
                    .where(
                      (doc) => [
                        'called',
                        'completed',
                      ].contains(doc.data()['status']),
                    )
                    .take(5);
                final current = sources
                    .map((doc) => 'doctor:${grant.clinicId}:${doc.id}')
                    .toSet();
                _removeNested('doctor:${grant.clinicId}:', current);
                for (final source in sources) {
                  final key = 'doctor:${grant.clinicId}:${source.id}';
                  if (_nested.containsKey(key)) continue;
                  _nested[key] = _watchSubscription(
                    db
                        .collection('referrals')
                        .where('clinicId', isEqualTo: grant.clinicId)
                        .where('referringDoctorId', isEqualTo: uid)
                        .where(
                          'patientId',
                          isEqualTo: source.data()['patientId'],
                        )
                        .where('sourceAppointmentId', isEqualTo: source.id)
                        .limit(20),
                    'referral',
                    'doctor',
                    grant.clinicId,
                  );
                }
              }, onError: (Object _) {}),
        );
      }
    }
    _watchQueues();
  }

  void _removeNested(String prefix, Set<String> current) {
    for (final key
        in _nested.keys
            .where((key) => key.startsWith(prefix) && !current.contains(key))
            .toList()) {
      unawaited(_nested.remove(key)!.cancel());
    }
  }

  void _watch(
    Query<Map<String, dynamic>> query,
    String kind,
    String role,
    String? clinic,
  ) {
    _subscriptions.add(_watchSubscription(query, kind, role, clinic));
  }

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>> _watchSubscription(
    Query<Map<String, dynamic>> query,
    String kind,
    String role,
    String? clinic,
  ) {
    final seen = <String, Timestamp>{};
    var initial = true;
    return query
        .snapshots(includeMetadataChanges: true)
        .listen(
          (page) {
            if (!active ||
                page.metadata.isFromCache ||
                page.metadata.hasPendingWrites) {
              return;
            }
            final current = page.docs.map((doc) => doc.id).toSet();
            seen.removeWhere((id, _) => !current.contains(id));
            for (final doc in page.docs) {
              final stamp = doc.data()['updatedAt'];
              if (stamp is! Timestamp) continue;
              final changed = !initial && seen[doc.id] != stamp;
              if (seen[doc.id] != stamp) {
                unawaited(_observed(doc, kind, role, clinic, changed));
              }
              seen[doc.id] = stamp;
            }
            initial = false;
          },
          onError: (Object _) {
            /* Revoked clinical access closes this observation. */
          },
        );
  }

  Future<void> _observed(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
    String kind,
    String role,
    String? clinic,
    bool changed,
  ) async {
    try {
      if (!active) return;
      final source = await snapshot.reference.get(
        const GetOptions(source: Source.server),
      );
      final data = source.data(), stamp = data?['updatedAt'];
      if (!active ||
          stamp is! Timestamp ||
          stamp != snapshot.data()?['updatedAt']) {
        return;
      }
      final item = switch (kind) {
        'appointment' => appointmentNotification(
          source.id,
          data!['status'],
          role,
          stamp.toDate(),
        ),
        'specialist' => specialistNotification(
          source.id,
          data!['status'],
          role,
          stamp.toDate(),
        ),
        _ => referralNotification(
          source.id,
          data!['status'],
          role,
          stamp.toDate(),
        ),
      };
      if (item == null) return;
      final stored = await FirestoreNotificationRepository(
        db,
        auth,
      ).observe(item, role, clinic);
      if (changed && stored && active) {
        await deliver('${item.id}:$role:${clinic ?? 'own'}');
      }
    } catch (_) {
      /* Offline, stale and denied observations do not deliver. */
    }
  }

  void _watchQueues() {
    _subscriptions.add(
      db
          .collection('queues')
          .where('patientId', isEqualTo: uid)
          .where('status', whereIn: ['waiting', 'called'])
          .limit(10)
          .snapshots(includeMetadataChanges: true)
          .listen((page) {
            if (!active ||
                page.metadata.isFromCache ||
                page.metadata.hasPendingWrites) {
              return;
            }
            final current = page.docs.map((doc) => 'queue:${doc.id}').toSet();
            _removeNested('queue:', current);
            for (final entry in page.docs) {
              final key = 'queue:${entry.id}',
                  stateId = entry.data()['stateId'];
              if (stateId is! String || _nested.containsKey(key)) continue;
              int? head;
              _nested[key] = db
                  .doc('queue_states/$stateId')
                  .snapshots(includeMetadataChanges: true)
                  .listen((state) {
                    final next = state.data()?['headTicket'];
                    if (!active ||
                        state.metadata.isFromCache ||
                        state.metadata.hasPendingWrites ||
                        next is! int) {
                      return;
                    }
                    if (head != null && head != next) {
                      unawaited(
                        _queueChange(entry.reference, state.reference, next),
                      );
                    }
                    head = next;
                  }, onError: (Object _) {});
            }
          }, onError: (Object _) {}),
    );
  }

  Future<void> _queueChange(
    DocumentReference<Map<String, dynamic>> queue,
    DocumentReference<Map<String, dynamic>> state,
    int head,
  ) async {
    try {
      final profile = await db
          .doc('users/$uid')
          .get(const GetOptions(source: Source.server));
      final own = await queue.get(const GetOptions(source: Source.server));
      final fresh = await state.get(const GetOptions(source: Source.server));
      if (active &&
          profile.data()?['status'] == 'active' &&
          own.data()?['patientId'] == uid &&
          ['waiting', 'called'].contains(own.data()?['status']) &&
          fresh.data()?['headTicket'] == head) {
        await deliver('queue-position:${queue.id}');
      }
    } catch (_) {
      /* Fresh server confirmation is required. */
    }
  }

  void cancel() {
    _active = false;
    for (final subscription in [..._subscriptions, ..._nested.values]) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _nested.clear();
  }
}
