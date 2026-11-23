import 'dart:js_interop';

@JS('medisyncAlerts.request')
external JSPromise<JSBoolean> _request();
@JS('medisyncAlerts.show')
external JSBoolean _show(JSString id, JSString kind);
@JS('medisyncAlerts.clear')
external void _clear(JSBoolean remindersOnly);
Future<bool> request() async => (await _request().toDart).toDart;
Future<void> show(String id, {bool workflow = false}) async {
  if (!_show(id.toJS, (workflow ? 'workflow' : 'reminder').toJS).toDart) {
    throw StateError('Browser notification unavailable');
  }
}

Future<void> clear({bool remindersOnly = false}) async =>
    _clear(remindersOnly.toJS);
