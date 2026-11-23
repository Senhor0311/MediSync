import 'dart:js_interop';

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external _Blob(JSArray<JSString> parts, _Options options);
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({JSString type});
}

@JS('URL.createObjectURL')
external JSString _createURL(_Blob blob);
@JS('URL.revokeObjectURL')
external void _revokeURL(JSString url);
@JS('document.createElement')
external _Anchor _element(JSString name);

extension type _Anchor._(JSObject _) implements JSObject {
  external set href(JSString value);
  external set download(JSString value);
  external void click();
}

Future<void> saveReadable(String html) async {
  final url = _createURL(
    _Blob([html.toJS].toJS, _Options(type: 'text/html;charset=utf-8'.toJS)),
  );
  final anchor = _element('a'.toJS)
    ..href = url
    ..download = 'medisync-medical-records.html'.toJS;
  anchor.click();
  await Future<void>.delayed(const Duration(seconds: 1));
  _revokeURL(url);
}

Future<void> clearReadable() async {}
