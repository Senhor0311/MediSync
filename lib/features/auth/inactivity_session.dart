import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A local privacy safeguard, not a replacement for Rules or token checks.
class InactivitySession extends StatefulWidget {
  const InactivitySession({
    super.key,
    required this.child,
    required this.onExpired,
    this.timeout = const Duration(minutes: 15),
  });
  final Widget child;
  final Future<void> Function() onExpired;
  final Duration timeout;

  /// Software keyboards deliver editing updates without hardware key events.
  static void reportActivity(BuildContext context) =>
      context.findAncestorStateOfType<_InactivitySessionState>()?._activity();
  @override
  State<InactivitySession> createState() => _InactivitySessionState();
}

class _InactivitySessionState extends State<InactivitySession>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime _lastActivity = DateTime.now();
  bool _expired = false;
  bool _background = false;
  final Stopwatch _elapsed = Stopwatch()..start();
  Duration _lastElapsed = Duration.zero;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_keyActivity);
    _activity();
  }

  void _activity() {
    if (_expired || _background) return;
    _lastActivity = DateTime.now();
    _lastElapsed = _elapsed.elapsed;
    _timer?.cancel();
    _timer = Timer(widget.timeout, _expire);
  }

  bool _keyActivity(KeyEvent event) {
    _activity();
    return false;
  }

  void _expire() {
    if (_expired || !mounted) return;
    _expired = true;
    setState(() {});
    // The caller locks synchronously. A failed/delayed remote sign-out must
    // never restore the navigator or its clinical overlays.
    unawaited(widget.onExpired().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    if (!_background) {
      final sinceWall = DateTime.now().difference(_lastActivity);
      final sinceMonotonic = _elapsed.elapsed - _lastElapsed;
      final elapsed = sinceWall > sinceMonotonic ? sinceWall : sinceMonotonic;
      if (elapsed >= widget.timeout) {
        _expire();
      } else {
        _timer?.cancel();
        _timer = Timer(widget.timeout - elapsed, _expire);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_keyActivity);
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _expired
      ? const Scaffold(
          body: Center(
            child: Text(
              'Session expired after inactivity. Sign in again. Unconfirmed saves may have completed; check history before creating another record.',
            ),
          ),
        )
      : Focus(
          onKeyEvent: (_, _) {
            _activity();
            return KeyEventResult.ignored;
          },
          child: Listener(
            onPointerDown: (_) => _activity(),
            onPointerSignal: (_) => _activity(),
            onPointerMove: (_) => _activity(),
            child: widget.child,
          ),
        );
}
