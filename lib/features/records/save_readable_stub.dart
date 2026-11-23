import 'package:flutter/services.dart';

Future<void> saveReadable(String html) async {
  await const MethodChannel('medisync/readable-export')
      .invokeMethod('save', {'html': html});
}

Future<void> clearReadable() async {
  try {
    await const MethodChannel('medisync/readable-export').invokeMethod('clear');
  } catch (_) {
    /* Unsupported platforms retain only the on-screen view. */
  }
}
