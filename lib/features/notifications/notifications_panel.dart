import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'notification_repository.dart';
import 'foreground_reminders.dart';

class NotificationsPanel extends StatefulWidget {
  const NotificationsPanel({
    super.key,
    required this.repository,
    required this.role,
    required this.clinicId,
    required this.onOpenSection,
  });

  final NotificationRepository repository;
  final String role;
  final String? clinicId;
  final ValueChanged<String> onOpenSection;

  @override
  State<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<NotificationsPanel> {
  List<NotificationItem>? _items;
  bool _busy = false;
  bool _failed = false;
  bool _unreadOnly = false;
  DocumentSnapshot<Map<String, dynamic>>? _cursor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NotificationsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role != widget.role ||
        oldWidget.clinicId != widget.clinicId ||
        oldWidget.repository != widget.repository) {
      _items = null;
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final repository = widget.repository;
      List<NotificationItem> items;
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      if (repository is NotificationHistory) {
        if (!more) await repository.load(widget.role, widget.clinicId);
        final page = await repository.history(
          widget.role,
          widget.clinicId,
          after: more ? _cursor : null,
        );
        items = page.items;
        cursor = page.cursor;
      } else {
        items = await repository.load(widget.role, widget.clinicId);
      }
      if (mounted) {
        setState(() {
          _items = more ? [...?_items, ...items] : items;
          _cursor = cursor;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(NotificationItem item, bool read) async {
    try {
      final repository = widget.repository;
      if (repository is NotificationHistory) {
        await repository.markRead(item, read);
        if (mounted) {
          setState(() {
            _items = [
              for (final old in _items ?? <NotificationItem>[])
                if (old.historyId == item.historyId)
                  NotificationItem(
                    id: old.id,
                    title: old.title,
                    body: old.body,
                    section: old.section,
                    changedAt: old.changedAt,
                    historyId: old.historyId,
                    read: read,
                  )
                else
                  old,
            ];
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Notifications', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 8),
      const Text(
        'Generic history of states observed while online. Refresh to check for changes. Updates missed while the app is closed are not guaranteed.',
      ),
      const SizedBox(height: 12),
      if (ForegroundReminders.instance case final reminders?)
        ListenableBuilder(
          listenable: reminders,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reminders.message),
              OutlinedButton(
                onPressed: reminders.toggle,
                child: Text(
                  reminders.enabled
                      ? 'Disable foreground reminders'
                      : 'Enable foreground reminders',
                ),
              ),
            ],
          ),
        ),
      OutlinedButton.icon(
        onPressed: _busy ? null : () => _load(),
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh'),
      ),
      if (widget.repository is NotificationHistory)
        FilterChip(
          label: const Text('Unread in loaded pages'),
          selected: _unreadOnly,
          onSelected: (value) => setState(() => _unreadOnly = value),
        ),
      if (_busy)
        const LinearProgressIndicator(key: Key('notification-loading')),
      if (_failed)
        const Text(
          'Notifications are unavailable. Check your connection and access, then refresh.',
          key: Key('notification-error'),
        ),
      if (_items?.isEmpty == true) const Text('No current updates to show.'),
      for (final item in _items ?? <NotificationItem>[])
        if (!_unreadOnly || !item.read)
          Card(
            child: ListTile(
              title: Text(item.title),
              subtitle: Text('${item.body}\n${item.changedAt.toLocal()}'),
              leading: Icon(
                item.read
                    ? Icons.drafts_outlined
                    : Icons.mark_email_unread_outlined,
              ),
              trailing: widget.repository is NotificationHistory
                  ? IconButton(
                      tooltip: item.read ? 'Mark unread' : 'Mark read',
                      icon: Icon(
                        item.read
                            ? Icons.mark_email_unread_outlined
                            : Icons.done,
                      ),
                      onPressed: _busy ? null : () => _read(item, !item.read),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () async {
                if (!item.read) await _read(item, true);
                if (mounted) widget.onOpenSection(item.section);
              },
            ),
          ),
      if (_cursor != null)
        OutlinedButton(
          onPressed: _busy ? null : () => _load(more: true),
          child: const Text('Load older updates'),
        ),
    ],
  );
}
