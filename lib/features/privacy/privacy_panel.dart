import '../../shared/data/history_page.dart';

import 'package:flutter/material.dart';

import 'privacy_repository.dart';
import 'own_export.dart';
import 'care_consent_panel.dart';
import '../encryption/clinical_crypto.dart';
import '../encryption/clinical_dialog.dart';

import 'package:flutter/services.dart';

class PrivacyPanel extends StatefulWidget {
  const PrivacyPanel({
    super.key,
    required this.repository,
    this.review = false,
  });

  final PrivacyRepository repository;
  final bool review;

  @override
  State<PrivacyPanel> createState() => _PrivacyPanelState();
}

class _PrivacyPanelState extends State<PrivacyPanel> {
  List<PrivacyRequest>? _requests;
  PrivacyRequestType _type = PrivacyRequestType.access;
  String? _next;
  bool _busy = false;
  bool _failed = false;
  Map<String, String> _exportCursors = {};
  ClinicalReadScope? _exportScope;
  OwnExportPage? _exportPage;
  void _locked() {
    if (ClinicalCrypto.instance?.unlocked == false) {
      _exportScope?.close();
      _exportPage?.clear();
      _exportCursors.clear();
    }
  }

  Future<void> _export({bool more = false}) async {
    if (_busy) return;
    final scope = _exportScope = ClinicalReadScope();
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final page = await (widget.repository as OwnDataExport).exportPage(
        after: more ? _exportCursors : const {},
      );
      if (!mounted || !scope.active) {
        page.clear();
        return;
      }
      _exportPage = page;
      setState(() => _exportCursors = page.cursors);
      await showClinicalDialog<void>(
        context: context,
        clear: page.clear,
        isActive: () => scope.active,
        builder: (context) => AlertDialog(
          title: const Text('Your data access export'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This contains decrypted personal information. Copy it only to a private destination. Clipboard contents may be visible to other applications. This page contains up to 20 items per collection; use the next-page button for remaining items.',
                  ),
                  SelectableText(page.json),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () async {
                if (!scope.active) return;
                try {
                  await Clipboard.setData(ClipboardData(text: page.json));
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Clipboard access failed. Select and copy the JSON manually, or retry with browser permission.',
                        ),
                      ),
                    );
                  }
                  return;
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Export page copied to clipboard. Save it privately.',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Copy JSON page'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      scope.close();
      _exportPage?.clear();
      _exportPage = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    ClinicalCrypto.instance?.addListener(_locked);
    _load();
  }

  @override
  void dispose() {
    _exportScope?.close();
    _exportPage?.clear();
    ClinicalCrypto.instance?.removeListener(_locked);
    super.dispose();
  }

  @override
  void didUpdateWidget(PrivacyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.review != widget.review) {
      _exportScope?.close();
      _exportPage?.clear();
      _exportCursors.clear();
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _busy = true;
      _failed = false;
      if (!more) {
        _requests = null;
        _next = null;
      }
    });
    try {
      final repository = widget.repository;
      final HistoryPage<PrivacyRequest>? page =
          repository is HistoryPager<PrivacyRequest>
          ? await (repository as HistoryPager<PrivacyRequest>).historyPage(
              after: more ? _next : null,
              scope: {'review': widget.review.toString()},
            )
          : null;
      final result =
          page?.items ??
          (widget.review
              ? await widget.repository.reviewQueue()
              : await widget.repository.ownRequests());
      if (mounted) {
        setState(() {
          _requests = {
            for (final row in [...?(more ? _requests : null), ...result])
              row.id: row,
          }.values.toList();
          _next = page?.next;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.repository.submit(_type);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startReview(String id) async {
    setState(() => _busy = true);
    try {
      await widget.repository.startReview(id);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.review ? 'Privacy request review' : 'Privacy requests',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 8),
      Text(
        widget.review
            ? 'Mark a request under review. Completion requires a separately verified operator action.'
            : 'Request access, correction or deletion of your account data. Requests are reviewed; submitting one does not change or export data.',
      ),
      const SizedBox(height: 8),
      const Text(
        'This prototype uses synthetic data. The draft privacy notice awaits approved wording before real-data use.',
      ),
      if (!widget.review) ...[
        if (widget.repository is FirestorePrivacyRepository)
          CareConsentPanel(
            repository: widget.repository as FirestorePrivacyRepository,
          ),
        if (widget.repository is OwnDataExport) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _export(),
            icon: const Icon(Icons.download),
            label: const Text('Export my accessible data'),
          ),
          if (_exportCursors.isNotEmpty)
            OutlinedButton(
              onPressed: _busy ? null : () => _export(more: true),
              child: const Text('Next export page'),
            ),
        ],
        const SizedBox(height: 16),
        DropdownButton<PrivacyRequestType>(
          value: _type,
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) setState(() => _type = value);
                },
          items: const [
            DropdownMenuItem(
              value: PrivacyRequestType.access,
              child: Text('Data access'),
            ),
            DropdownMenuItem(
              value: PrivacyRequestType.correction,
              child: Text('Data correction'),
            ),
            DropdownMenuItem(
              value: PrivacyRequestType.deletion,
              child: Text('Data deletion'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Submit request'),
        ),
      ],
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy ? null : _load,
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh'),
      ),
      if (_busy) const LinearProgressIndicator(key: Key('privacy-loading')),
      if (_failed)
        const Text(
          'Privacy requests are unavailable. Check your connection and access, then refresh.',
          key: Key('privacy-error'),
        ),
      if (_requests?.isEmpty == true) const Text('No requests to show.'),
      if (_next != null)
        OutlinedButton(
          onPressed: _busy ? null : () => _load(more: true),
          child: const Text('Load more requests'),
        ),
      for (final request in _requests ?? <PrivacyRequest>[])
        Card(
          child: ListTile(
            title: Text(_typeLabel(request.type)),
            subtitle: Text(
              widget.review
                  ? 'Account ${request.userId} · ${_statusLabel(request.status)}'
                  : _statusLabel(request.status),
            ),
            trailing:
                widget.review && request.status == PrivacyRequestStatus.pending
                ? TextButton(
                    onPressed: _busy ? null : () => _startReview(request.id),
                    child: const Text('Start review'),
                  )
                : null,
          ),
        ),
    ],
  );
}

String _typeLabel(PrivacyRequestType type) => switch (type) {
  PrivacyRequestType.access => 'Data access',
  PrivacyRequestType.correction => 'Data correction',
  PrivacyRequestType.deletion => 'Data deletion',
};

String _statusLabel(PrivacyRequestStatus status) => switch (status) {
  PrivacyRequestStatus.pending => 'Pending review',
  PrivacyRequestStatus.underReview => 'Under review',
  PrivacyRequestStatus.fulfilled => 'Fulfilled by operator',
  PrivacyRequestStatus.partiallyFulfilled =>
    'Partially fulfilled · retained items remain',
  PrivacyRequestStatus.declined => 'Declined after review',
};
