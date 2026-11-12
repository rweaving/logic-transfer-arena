import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'arena_ws_stub.dart';

@JS('location')
external _JsLocation get _windowLocation;

extension type _JsLocation._(JSObject _) implements JSObject {
  external String get protocol;
  external String get host;
}

@JS('fetch')
external JSPromise<_JsResponse> _jsFetch(String url, [_JsRequestInit? init]);

extension type _JsRequestInit._(JSObject _) implements JSObject {
  external factory _JsRequestInit({String method});
}

extension type _JsResponse._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
}

@JS('WebSocket')
extension type _JsWebSocket._(JSObject _) implements JSObject {
  external factory _JsWebSocket(String url);
  external set binaryType(String value);
  external int get readyState;
  external set onopen(JSFunction? handler);
  external set onmessage(JSFunction? handler);
  external set onclose(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external void send(JSAny data);
  external void close();
}

extension type _JsMessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

String platformDefaultHttpBase() {
  try {
    final String proto = _windowLocation.protocol;
    final String host = _windowLocation.host;
    if (host.isNotEmpty) {
      return '$proto//$host';
    }
  } catch (_) {}
  return 'http://localhost:8080';
}

String platformDefaultWsBase() {
  try {
    final String proto =
        _windowLocation.protocol == 'https:' ? 'wss:' : 'ws:';
    final String host = _windowLocation.host;
    if (host.isNotEmpty) {
      return '$proto//$host';
    }
  } catch (_) {}
  return 'ws://localhost:8080';
}

Future<String?> platformRequestRoomCode(String httpBase) async {
  try {
    final _JsResponse res = await _jsFetch(
      '$httpBase/api/rooms',
      _JsRequestInit(method: 'POST'),
    ).toDart;
    if (res.ok) {
      final JSString bodyJs = await res.text().toDart;
      final Map<String, dynamic> decoded =
          jsonDecode(bodyJs.toDart) as Map<String, dynamic>;
      return decoded['roomCode'] as String?;
    }
  } catch (_) {}
  return null;
}

final class _WebWsClient implements PlatformWsClient {
  late final _JsWebSocket _ws;
  bool _closed = false;

  _WebWsClient({
    required String wsUrl,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(Uint8List bytes) onBinary,
    required void Function() onClose,
    required void Function(String error) onError,
  }) {
    try {
      _ws = _JsWebSocket(wsUrl);
      _ws.binaryType = 'arraybuffer';
      _ws.onopen = ((JSObject _) {
        if (!_closed) onOpen();
      }).toJS;
      _ws.onmessage = ((_JsMessageEvent ev) {
        if (_closed) return;
        final JSAny? payload = ev.data;
        if (payload == null) return;
        if (payload.isA<JSString>()) {
          onText((payload as JSString).toDart);
        } else if (payload.isA<JSArrayBuffer>()) {
          final ByteBuffer buf = (payload as JSArrayBuffer).toDart;
          onBinary(buf.asUint8List());
        }
      }).toJS;
      _ws.onclose = ((JSObject _) {
        if (!_closed) {
          _closed = true;
          onClose();
        }
      }).toJS;
      _ws.onerror = ((JSObject _) {
        if (!_closed) {
          onError('WebSocket connection error');
        }
      }).toJS;
    } catch (e) {
      _closed = true;
      onError(e.toString());
    }
  }

  @override
  bool get isOpen => !_closed && _ws.readyState == 1;

  @override
  void sendText(String text) {
    if (isOpen) _ws.send(text.toJS);
  }

  @override
  void sendBytes(Uint8List bytes) {
    if (isOpen) _ws.send(bytes.toJS);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _ws.close();
    } catch (_) {}
  }
}

PlatformWsClient platformConnectWs({
  required String wsUrl,
  required void Function() onOpen,
  required void Function(String text) onText,
  required void Function(Uint8List bytes) onBinary,
  required void Function() onClose,
  required void Function(String error) onError,
}) =>
    _WebWsClient(
      wsUrl: wsUrl,
      onOpen: onOpen,
      onText: onText,
      onBinary: onBinary,
      onClose: onClose,
      onError: onError,
    );
