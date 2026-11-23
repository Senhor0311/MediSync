import 'package:flutter/material.dart';

import 'dart:async';

import 'clinical_crypto.dart';

/// Root navigator dialogs outlive their caller unless explicitly closed on lock.
Future<T?> showClinicalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  VoidCallback? clear,
  bool barrierDismissible = true,
  Future<bool> Function()? authorised,
  bool Function()? isActive,
}) async {
  BuildContext? dialogContext;
  final crypto = ClinicalCrypto.instance;
  final generation = crypto?.generation;
  bool closed = false;
  bool valid() =>
      !closed &&
      context.mounted &&
      (isActive?.call() ?? true) &&
      (crypto == null || crypto.isCurrent(generation!));
  void close() {
    closed = true;
    clear?.call();
    final current = dialogContext;
    if (current != null && current.mounted) {
      final route = ModalRoute.of(current);
      if (route != null && route.isActive) {
        Navigator.of(current).removeRoute(route);
      }
    }
  }

  void locked() {
    if (crypto?.unlocked == false) {
      close();
    }
  }

  crypto?.addListener(locked);
  bool checking = false;
  var ticks = 0;
  final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
    if (!valid()) {
      close();
      return;
    }
    if (++ticks % 30 != 0 || authorised == null) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (checking ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    checking = true;
    try {
      if (!await authorised() || !valid()) close();
    } catch (_) {
      /* A connection failure does not establish revocation. The next action still checks the server. */
    } finally {
      checking = false;
    }
  });
  try {
    if (!valid()) return null;
    return await showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (c) {
        dialogContext = c;
        if (!valid()) return const SizedBox.shrink();
        return builder(c);
      },
    );
  } finally {
    closed = true;
    timer.cancel();
    crypto?.removeListener(locked);
    clear?.call();
  }
}

/// Cancels results after a lock/account change, including lock then re-unlock.
/// Owners must also check mounted/disposal before presenting a returned result.
class ClinicalReadScope {
  ClinicalReadScope() : crypto = ClinicalCrypto.instance {
    generation = crypto?.generation;
  }
  final ClinicalCrypto? crypto;
  late final int? generation;
  bool _active = true;
  bool get active =>
      _active && (crypto == null || crypto!.isCurrent(generation!));
  void close() => _active = false;
  void check() {
    if (!active) {
      throw const ClinicalCryptoFailure(
        'Clinical view closed. Unlock and retry. An unconfirmed save may still have completed; check history first.',
      );
    }
  }
}
