import 'package:flutter/material.dart';

import 'dashboard_repository.dart';
import '../queue/queue_repository.dart';

class DashboardSummary extends StatefulWidget {
  const DashboardSummary({
    super.key,
    required this.repository,
    required this.role,
    required this.clinicId,
    required this.uid,
    required this.onOpenSection,
  });
  final DashboardRepository repository;
  final String role, uid;
  final String? clinicId;
  final ValueChanged<String> onOpenSection;
  @override
  State<DashboardSummary> createState() => _DashboardSummaryState();
}

class _DashboardSummaryState extends State<DashboardSummary> {
  late Future<DashboardSnapshot> _result;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _result = widget.repository.load(widget.role, widget.clinicId, widget.uid);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DashboardSnapshot>(
    future: _result,
    builder: (context, snapshot) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: snapshot.connectionState == ConnectionState.waiting
                ? null
                : () => setState(_reload),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh overview'),
          ),
        ),
        if (snapshot.connectionState == ConnectionState.waiting)
          const LinearProgressIndicator()
        else if (snapshot.hasError) ...[
          Text(
            snapshot.error is QueueConfigurationUnavailable
                ? 'Clinic queue setup is incomplete. Ask the local emulator operator to configure it, then refresh.'
                : 'Overview is unavailable. Refresh to try again.',
          ),
        ] else if (snapshot.hasData) ...[
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final metric in snapshot.data!.metrics.entries)
                  SizedBox(
                    width: (constraints.maxWidth - 16) / 2,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${metric.value}',
                              style: Theme.of(context).textTheme.headlineLarge,
                            ),
                            Text(metric.key),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (widget.role == 'doctor')
            Text(
              'Current Queue',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          if (widget.role == 'specialist')
            Text(
              'Referral inbox',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          if (snapshot.data!.items.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(snapshot.data!.emptyMessage),
              ),
            ),
          for (final item in snapshot.data!.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  title: Text(item.title),
                  subtitle: Text(item.subtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onOpenSection(item.section),
                ),
              ),
            ),
          Text(
            snapshot.data!.coverage ?? 'Overview shows the loaded set (up to 50 per query). Refresh for current information.',
          ),
        ],
      ],
    ),
  );
}
