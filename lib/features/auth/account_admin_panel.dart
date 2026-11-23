import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../shared/data/server_transaction.dart';

class AccountAdministration {
  const AccountAdministration(this.db, this.auth);
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> events(
    String target, {
    DocumentSnapshot? after,
  }) async {
    Query<Map<String, dynamic>> query = db
        .collection('account_status_events')
        .where('targetId', isEqualTo: target)
        .orderBy('occurredAt', descending: true)
        .orderBy(FieldPath.documentId)
        .limit(20);
    if (after != null) query = query.startAfterDocument(after);
    return (await query.get(const GetOptions(source: Source.server))).docs;
  }

  Future<void> setSuspended(
    String target,
    bool suspended,
    String reason,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9-]{1,128}$').hasMatch(target) ||
        target == auth.currentUser?.uid ||
        reason.trim().length < 10 ||
        reason.trim().length > 300) {
      throw ArgumentError(
        'Enter another verified account UID and a review reason of 10–300 characters.',
      );
    }
    final actor = auth.currentUser!.uid,
        event = db.collection('account_status_events').doc();
    await runServerTransaction(db, actor, (tx) async {
      final statusRef = db.doc('account_status/$target'),
          old = (await tx.get(statusRef)).data(),
          status = suspended ? 'suspended' : 'active',
          previous = suspended ? 'active' : 'suspended',
          revision = (old?['revision'] as int? ?? 0) + 1,
          now = FieldValue.serverTimestamp();
      tx.update(db.doc('users/$target'), {'status': status, 'updatedAt': now});
      tx.set(statusRef, {
        'uid': target,
        'status': status,
        'revision': revision,
        'eventId': event.id,
        'updatedBy': actor,
        'updatedAt': now,
      });
      tx.set(event, {
        'eventId': event.id,
        'targetId': target,
        'actorId': actor,
        'fromStatus': previous,
        'toStatus': status,
        'statusRevision': revision,
        'reason': reason.trim(),
        'occurredAt': now,
      });
    });
  }
}

class AccountAdminPanel extends StatefulWidget {
  const AccountAdminPanel({super.key, required this.service});
  final AccountAdministration service;
  @override
  State<AccountAdminPanel> createState() => _AccountAdminPanelState();
}

class _AccountAdminPanelState extends State<AccountAdminPanel> {
  final uid = TextEditingController(), reason = TextEditingController();
  bool busy = false;
  String? message;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> events = [];
  DocumentSnapshot? cursor;
  String? subject;
  Future<void> loadEvents({bool more = false}) async {
    setState(() => busy = true);
    try {
      final target = uid.text.trim(),
          append = more && subject == uid.text.trim(),
          rows = await widget.service.events(
            target,
            after: append ? cursor : null,
          );
      if (mounted) {
        setState(() {
          events = [if (append) ...events, ...rows];
          cursor = rows.length == 20 ? rows.last : null;
          subject = target;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Account events could not be loaded for this UID and access.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    uid.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> change(bool suspend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          suspend
              ? 'Suspend application access?'
              : 'Restore application access?',
        ),
        content: Text(
          'Target: ${uid.text.trim()}. This changes application account state and appends a protected event. It does not assign roles, restore old consent grants, disable Firebase Authentication, delete data or affect platform-administrator accounts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply reviewed change'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => busy = true);
    try {
      await widget.service.setSuspended(uid.text.trim(), suspend, reason.text);
      if (mounted) {
        setState(
          () => message = suspend
              ? 'Application access suspended. Firebase Authentication disable/revocation is a separate trusted operator action.'
              : 'Application access restored with existing roles. Withdrawn consent and expired grants are not renewed.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'No account change was confirmed. Check the exact UID, current state, review reason, platform role and recent sign-in. Self/platform-admin targets are protected.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Account administration',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const Text(
        'Use an exact UID supplied through a reviewed support request. No global patient directory or clinical content is exposed. These controls change application access only; privileged Auth disable/delete and platform-admin lifecycle remain trusted operator responsibilities.',
      ),
      TextField(
        controller: uid,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Reviewed account UID'),
        maxLength: 128,
      ),
      TextField(
        controller: reason,
        enabled: !busy,
        decoration: const InputDecoration(
          labelText: 'Administrative reason (no clinical information)',
        ),
        maxLength: 300,
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: busy ? null : () => change(true),
            child: const Text('Suspend app access'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => change(false),
            child: const Text('Restore app access'),
          ),
          TextButton(
            onPressed: busy ? null : loadEvents,
            child: const Text('View status events'),
          ),
        ],
      ),
      for (final e in events)
        Card(
          child: ListTile(
            title: Text('${e.data()['fromStatus']} → ${e.data()['toStatus']}'),
            subtitle: Text(
              '${e.data()['reason']} · actor ${e.data()['actorId']} · ${(e.data()['occurredAt'] as Timestamp).toDate().toLocal()}',
            ),
          ),
        ),
      if (cursor != null)
        TextButton(
          onPressed: busy ? null : () => loadEvents(more: true),
          child: const Text('Load older status events'),
        ),
      const Text(
        'These paired status-change events are limited activity records. They do not audit every clinical read or denied request.',
      ),
      if (busy) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ],
  );
}
