import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/auth_models.dart';
import 'local_alerts.dart';
import 'reminder_engine.dart';
import 'workflow_observer.dart';

class ForegroundReminders extends ChangeNotifier with WidgetsBindingObserver {
  ForegroundReminders(this.db, this.auth, this.controller) {
    engine = ReminderEngine(
      validate: _validate,
      deliver: (row) => alerts.show(row.id),
    );
    controller.addListener(_access);
    WidgetsBinding.instance.addObserver(this);
    instance = this;
  }
  static ForegroundReminders? instance;
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final AuthController controller;
  final alerts = LocalAlerts();
  late final ReminderEngine engine;
  WorkflowObserver? _workflows;
  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
  _subscriptions = [];
  final Map<String, List<ReminderReservation>> _rows = {};
  bool enabled = false, _foreground = true;
  String? _uid;
  String message =
      'Alerts are off. Enable for this signed-in session. The app must stay open and active; no background delivery is promised.';
  int _epoch = 0;

  Future<void> toggle() async {
    if (enabled) {
      await _stop();
      return;
    }
    try {
      // Called directly from an explicit button so browser permission retains
      // the user gesture. Permission never starts during sign-in or app launch.
      if (!await alerts.request()) {
        message = 'System alerts were denied or are unsupported. In-app history remains available.';
        notifyListeners();
        return;
      }
      if (controller.access.kind != AccessKind.ready ||
          auth.currentUser == null) {
        return;
      }
      enabled = true;
      _uid = auth.currentUser!.uid;
      message = 'Foreground alerts enabled for this session: reminders about five minutes before booked visits and observed referral/queue updates. Keep the app open and active. Delivery is best effort; bounded listeners can miss older updates.';
      _listen();
      notifyListeners();
    } catch (_) {
      message = 'Could not enable alerts. Check system notification permission and retry.';
      notifyListeners();
    }
  }

  void _access() {
    if (enabled &&
        (controller.access.kind != AccessKind.ready ||
            auth.currentUser?.uid != _uid)) {
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!enabled) return;
    _cancelListeners();
    if (_foreground) _listen();
  }

  void _cancelListeners() {
    _epoch++;
    _workflows?.cancel();
    _workflows = null;
    engine.cancel();
    _rows.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(alerts.clear().catchError((_) {}));
  }

  Future<void> _stop() async {
    enabled = false;
    _uid = null;
    _cancelListeners();
    engine.reset();
    message = 'Alerts are off. In-app history remains available.';
    notifyListeners();
  }

  void _listen() {
    if (!_foreground || !enabled || _uid == null) return;
    final epoch = ++_epoch;
    _workflows = WorkflowObserver(
      db,
      auth,
      _uid!,
      controller.access.grants,
      deliver: (id) async {
        if (enabled && _foreground && epoch == _epoch) {
          await alerts.show(id, workflow: true);
        }
      },
    )..start();
    for (final collection in ['appointments', 'specialist_appointments']) {
      final query = db
          .collection(collection)
          .where('patientId', isEqualTo: _uid)
          .where('status', isEqualTo: 'booked')
          .where('startAt', isGreaterThan: Timestamp.now())
          .orderBy('startAt')
          .limit(20);
      _subscriptions.add(
        query
            .snapshots(includeMetadataChanges: true)
            .listen(
              (page) {
                if (epoch != _epoch) return;
                // Cache-only or pending snapshots cancel timers rather than implying
                // a reservation is still current while disconnected.
                _rows[collection] =
                    page.metadata.isFromCache || page.metadata.hasPendingWrites
                    ? []
                    : [
                        for (final doc in page.docs)
                          if (doc.data()['startAt'] is Timestamp)
                            ReminderReservation(
                              '$collection/${doc.id}',
                              (doc.data()['startAt'] as Timestamp).toDate(),
                            ),
                      ];
                engine.replace(_rows.values.expand((rows) => rows).toList());
                unawaited(alerts.clear(remindersOnly: true).catchError((_) {}));
              },
              onError: (Object error) {
                if (epoch != _epoch) return;
                _rows[collection] = [];
                engine.replace(_rows.values.expand((rows) => rows).toList());
                message = 'Reminders could not be refreshed. Check connectivity/access; disable and re-enable to retry.';
                notifyListeners();
              },
            ),
      );
    }
  }

  Future<bool> _validate(ReminderReservation row) async {
    final uid = _uid;
    if (!enabled ||
        !_foreground ||
        uid == null ||
        auth.currentUser?.uid != uid) {
      return false;
    }
    final profile = await db
        .doc('users/$uid')
        .get(const GetOptions(source: Source.server));
    final snapshot = await db
        .doc(row.id)
        .get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    return enabled &&
        _foreground &&
        auth.currentUser?.uid == uid &&
        profile.data()?['status'] == 'active' &&
        data?['patientId'] == uid &&
        data?['status'] == 'booked' &&
        data?['startAt'] is Timestamp &&
        (data!['startAt'] as Timestamp).toDate() == row.startAt;
  }

  @override
  void dispose() {
    enabled = false;
    _cancelListeners();
    engine.reset();
    controller.removeListener(_access);
    WidgetsBinding.instance.removeObserver(this);
    if (identical(instance, this)) instance = null;
    super.dispose();
  }
}
