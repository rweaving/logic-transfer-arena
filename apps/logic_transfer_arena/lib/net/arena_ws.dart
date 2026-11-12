import 'dart:math' as math;
import 'dart:typed_data';

import 'arena_ws_stub.dart' show PlatformWsClient;
import 'arena_ws_stub.dart'
    if (dart.library.js_interop) 'arena_ws_web.dart'
    if (dart.library.io) 'arena_ws_io.dart' as impl;

export 'arena_ws_stub.dart' show PlatformWsClient;

/// Cross-platform WebSocket & Room Code transport facade (Web Wasm/JS + Mobile/Desktop IO).
abstract final class ArenaWsTransport {
  static String defaultHttpBase() => impl.platformDefaultHttpBase();

  static String defaultWsBase() => impl.platformDefaultWsBase();

  static Future<String> createOrGenerateRoomCode({String? httpBase}) async {
    final String base = httpBase ?? defaultHttpBase();
    final String? serverCode = await impl.platformRequestRoomCode(base);
    if (serverCode != null && serverCode.isNotEmpty) {
      return serverCode.toUpperCase();
    }
    const String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final math.Random rng = math.Random();
    return List<String>.generate(4, (_) => chars[rng.nextInt(chars.length)])
        .join();
  }

  static PlatformWsClient connectRoom({
    required String roomCode,
    String? wsBase,
    String? customBoardHash,
    required void Function() onOpen,
    required void Function(String text) onText,
    required void Function(Uint8List bytes) onBinary,
    required void Function() onClose,
    required void Function(String error) onError,
  }) {
    final String cleanBase =
        (wsBase ?? defaultWsBase()).replaceAll(RegExp(r'/$'), '');
    final String cleanCode = roomCode.trim().toUpperCase();
    final String query =
        (customBoardHash != null && customBoardHash.startsWith('#arena=v1.'))
            ? '?board=${Uri.encodeQueryComponent(customBoardHash)}'
            : '';
    final String url = '$cleanBase/ws/room/$cleanCode$query';
    return impl.platformConnectWs(
      wsUrl: url,
      onOpen: onOpen,
      onText: onText,
      onBinary: onBinary,
      onClose: onClose,
      onError: onError,
    );
  }
}
