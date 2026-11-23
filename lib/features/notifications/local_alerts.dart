import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_alerts_stub.dart'
    if (dart.library.js_interop) 'local_alerts_web.dart'
    as web;

class LocalAlerts {
  static const _channel = MethodChannel('medisync/foreground-alerts');
  Future<bool> request() async {
    if (kIsWeb) return web.request();
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return await _channel.invokeMethod<bool>('request') ?? false;
  }

  Future<void> show(String id, {bool workflow = false}) async {
    if (kIsWeb) {
      await web.show(id, workflow: workflow);
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('show', {
        'id': id,
        'kind': workflow ? 'workflow' : 'reminder',
      });
    }
  }

  Future<void> clear({bool remindersOnly = false}) async {
    if (kIsWeb) {
      await web.clear(remindersOnly: remindersOnly);
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>(
        remindersOnly ? 'clearReminders' : 'clear',
      );
    }
  }
}
