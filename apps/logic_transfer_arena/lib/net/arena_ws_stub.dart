import 'dart:typed_data';

abstract interface class PlatformWsClient {
  bool get isOpen;
  void sendText(String text);
  void sendBytes(Uint8List bytes);
  void close();
}

String platformDefaultHttpBase() => 'http://localhost:8080';

String platformDefaultWsBase() => 'ws://localhost:8080';

Future<String?> platformRequestRoomCode(String httpBase) async => null;

PlatformWsClient platformConnectWs({
  required String wsUrl,
  required void Function() onOpen,
  required void Function(String text) onText,
  required void Function(Uint8List bytes) onBinary,
  required void Function() onClose,
  required void Function(String error) onError,
}) {
  throw UnsupportedError('WebSocket unsupported on this platform stub.');
}
