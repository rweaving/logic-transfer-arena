import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'arena_ws_stub.dart';

String platformDefaultHttpBase() => 'http://localhost:8080';

String platformDefaultWsBase() => 'ws://localhost:8080';

Future<String?> platformRequestRoomCode(String httpBase) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    final HttpClientRequest req =
        await client.postUrl(Uri.parse('$httpBase/api/rooms'));
    final HttpClientResponse res = await req.close();
    if (res.statusCode == 200) {
      final String body = await res.transform(utf8.decoder).join();
      final Map<String, dynamic> decoded =
          jsonDecode(body) as Map<String, dynamic>;
      return decoded['roomCode'] as String?;
    }
  } catch (_) {
    // Fallback to client-generated room code if endpoint unreachable.
  } finally {
    client.close(force: true);
  }
  return null;
}

final class _IoWsClient implements PlatformWsClient {
  WebSocket? _ws;
  bool _closed = false;

  _IoWsClient({
    required String wsUrl,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(Uint8List bytes) onBinary,
    required void Function() onClose,
    required void Function(String error) onError,
  }) {
    WebSocket.connect(wsUrl).then((WebSocket socket) {
      if (_closed) {
        socket.close();
        return;
      }
      _ws = socket;
      onOpen();
      socket.listen(
        (Object? event) {
          if (event is String) {
            onText(event);
          } else if (event is List<int>) {
            onBinary(event is Uint8List ? event : Uint8List.fromList(event));
          }
        },
        onDone: () {
          if (!_closed) {
            _closed = true;
            onClose();
          }
        },
        onError: (Object err) {
          onError(err.toString());
        },
      );
    }).catchError((Object err) {
      if (!_closed) {
        onError(err.toString());
        onClose();
      }
    });
  }

  @override
  bool get isOpen => !_closed && _ws != null && _ws!.readyState == WebSocket.open;

  @override
  void sendText(String text) {
    if (isOpen) _ws!.add(text);
  }

  @override
  void sendBytes(Uint8List bytes) {
    if (isOpen) _ws!.add(bytes);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _ws?.close();
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
    _IoWsClient(
      wsUrl: wsUrl,
      onOpen: onOpen,
      onText: onText,
      onBinary: onBinary,
      onClose: onClose,
      onError: onError,
    );
