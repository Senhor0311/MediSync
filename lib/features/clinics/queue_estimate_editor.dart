import 'package:flutter/material.dart';

import 'clinic_repository.dart';

class QueueEstimateEditor extends StatefulWidget {
  const QueueEstimateEditor({
    super.key,
    required this.repository,
    required this.clinicId,
  });
  final QueueEstimateSettings repository;
  final String clinicId;
  @override
  State<QueueEstimateEditor> createState() => _QueueEstimateEditorState();
}

class _QueueEstimateEditorState extends State<QueueEstimateEditor> {
  final value = TextEditingController();
  bool busy = false;
  String? message;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    generation++;
    value.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(QueueEstimateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clinicId != widget.clinicId ||
        oldWidget.repository != widget.repository) {
      load();
    }
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final estimate = await widget.repository.queueEstimate(widget.clinicId);
      if (mounted && current == generation) {
        setState(() {
          value.text = estimate?.toString() ?? '';
          message = estimate == null ? 'Set up the clinic queue first.' : null;
        });
      }
    } catch (_) {
      if (mounted && current == generation) {
        setState(() => message = 'Estimate unavailable. Retry.');
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final minutes = int.tryParse(value.text);
    if (minutes == null || minutes < 1 || minutes > 120) {
      setState(() => message = 'Enter a whole number from 1 to 120.');
      return;
    }
    setState(() => busy = true);
    final current = ++generation;
    try {
      await widget.repository.setQueueEstimate(widget.clinicId, minutes);
      if (mounted && current == generation) {
        setState(() => message = 'Approximate queue estimate saved.');
      }
    } catch (_) {
      if (mounted && current == generation) {
        setState(
          () => message =
              'Estimate was not confirmed. Check setup, access and connection.',
        );
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Approximate wait = tickets ahead (including any active call) × the configured minutes per patient. This is an administrative assumption, not a clinical prediction; cancellations are removed from the waiting list.',
      ),
      TextField(
        controller: value,
        enabled: !busy,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Approximate minutes per patient (1–120)',
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: busy ? null : save,
            child: const Text('Save queue estimate'),
          ),
          TextButton(
            onPressed: busy ? null : load,
            child: const Text('Reload estimate'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ],
  );
}
