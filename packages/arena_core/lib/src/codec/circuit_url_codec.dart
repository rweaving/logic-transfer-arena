import 'dart:convert';
import 'dart:typed_data';

import '../ai/arena_ai.dart';
import '../gen/fairness_validator.dart';
import '../gen/procedural_generator.dart';
import '../math/xoshiro128pp.dart';
import '../sim/arena_topology.dart';
import '../sim/signal_types.dart';

/// Pure-Dart URL-safe binary circuit hash codec (`#arena=v1.<base64url>`).
///
/// Uses CSR adjacency bit-packing (implicit source nodes + conditional SR-Latch
/// pin roles) + CRC-16-CCITT, encoding full 40+ node / 65+ wire arenas in
/// `~175-235` URL characters with zero `dart:io` dependencies.
abstract final class CircuitUrlCodec {
  static const String hashPrefix = '#arena=v1.';
  static const int _magicHi = 0x4C; // 'L'
  static const int _magicLo = 0x54; // 'T'
  static const int _schemaVersion = 1;

  /// Encodes an [ArenaTopology] into a compact `#arena=v1.<payload>` URL fragment.
  static String encodeUrlFragment(ArenaTopology topology) {
    final Uint8List raw = encodeBytes(topology);
    final String b64 = base64UrlEncode(raw).replaceAll('=', '');
    return '$hashPrefix$b64';
  }

  /// Decodes a `#arena=v1.<payload>` fragment (or full URL containing it) back into [ArenaTopology].
  static ArenaTopology decodeUrlFragment(String urlOrFragment) {
    final int idx = urlOrFragment.indexOf(hashPrefix);
    final String payload = idx >= 0
        ? urlOrFragment.substring(idx + hashPrefix.length).trim()
        : urlOrFragment.trim();

    final int padLen = (4 - (payload.length % 4)) % 4;
    final String padded = payload + ('=' * padLen);
    final Uint8List raw = base64Url.decode(padded);
    return decodeBytes(raw);
  }

  /// Bit-packs [topology] into compact binary with CRC-16-CCITT integrity verification.
  static Uint8List encodeBytes(ArenaTopology topology) {
    final int n = topology.nodeCount;
    final int e = topology.edgeCount;
    if (n > ArenaTopology.maxSupportedNodes || e > 255) {
      throw ArgumentError('Circuit exceeds Arena maximum (64 nodes, 255 edges).');
    }

    final _BitWriter bw = _BitWriter();
    bw.writeBits(_magicHi, 8);
    bw.writeBits(_magicLo, 8);
    bw.writeBits(_schemaVersion, 4);
    bw.writeBits(topology.archetype.index & 0x7, 3);
    bw.writeBits(topology.allowPrepPhase ? 1 : 0, 1);
    bw.writeBits(topology.cyanInitialPulsers.clamp(1, 15), 4);
    bw.writeBits(topology.amberInitialPulsers.clamp(1, 15), 4);
    bw.writeBits(topology.pulserBurnTicks.clamp(1, 255), 8);
    bw.writeBits(topology.burstBurnTicks.clamp(1, 63), 6);
    bw.writeBits((topology.liveDurationTicks ~/ 10).clamp(1, 63), 6);
    bw.writeBits(n, 7);

    // 20 bits per node: type(4b) | param(4b) | gridX(6b: 0..63) | gridY(6b: 0..63)
    for (int i = 0; i < n; i++) {
      bw.writeBits(topology.nodeType[i] & 0x0F, 4);
      bw.writeBits(topology.nodeParam[i] & 0x0F, 4);
      bw.writeBits((topology.nodeX[i].clamp(0.0, 1.0) * 63.0).round(), 6);
      bw.writeBits((topology.nodeY[i].clamp(0.0, 1.0) * 63.0).round(), 6);
    }

    // Group edges by source node: write `1` bit + `dst(6b)` (+ `resetBit(1b)` iff dst is srLatch), terminated by `0` bit.
    final List<List<WirePath>> adj =
        List<List<WirePath>>.generate(n, (_) => <WirePath>[]);
    for (final WirePath w in topology.wires) {
      adj[w.srcNode].add(w);
    }

    for (int src = 0; src < n; src++) {
      for (final WirePath w in adj[src]) {
        bw.writeBits(1, 1);
        bw.writeBits(w.dstNode & 0x3F, 6);
        if (topology.typeOf(w.dstNode) == NodeType.srLatch) {
          bw.writeBits(w.pinRole == PinRole.reset ? 1 : 0, 1);
        }
      }
      bw.writeBits(0, 1);
    }

    final Uint8List body = bw.toBytes();
    final int crc = crc16Ccitt(body);
    final Uint8List out = Uint8List(body.length + 2);
    out.setRange(0, body.length, body);
    out[body.length] = (crc >>> 8) & 0xFF;
    out[body.length + 1] = crc & 0xFF;
    return out;
  }

  static ArenaTopology decodeBytes(Uint8List raw) {
    if (raw.length < 10 || raw[0] != _magicHi || raw[1] != _magicLo) {
      throw const FormatException('Invalid Logic Transfer Arena circuit header.');
    }

    final int bodyLen = raw.length - 2;
    final int expectedCrc = (raw[bodyLen] << 8) | raw[bodyLen + 1];
    final int actualCrc = crc16Ccitt(raw.sublist(0, bodyLen));
    if (expectedCrc != actualCrc) {
      throw const FormatException('Circuit hash CRC-16 checksum mismatch.');
    }

    final _BitReader br = _BitReader(raw, bodyLen);
    br.readBits(16); // magic
    final int ver = br.readBits(4);
    if (ver != _schemaVersion) {
      throw FormatException('Unsupported circuit schema version: $ver');
    }
    final int archIdx = br.readBits(3);
    final bool allowPrep = br.readBits(1) == 1;
    final int cyanPulsers = br.readBits(4);
    final int amberPulsers = br.readBits(4);
    final int pulserBurn = br.readBits(8);
    final int burstBurn = br.readBits(6);
    final int liveTicks = br.readBits(6) * 10;
    final int n = br.readBits(7);
    if (n <= 0 || n > ArenaTopology.maxSupportedNodes) {
      throw FormatException('Invalid node count in circuit hash: $n');
    }

    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: 'shared_${actualCrc.toRadixString(16).padLeft(4, '0')}',
      title:
          'Custom Shared Arena #${actualCrc.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      archetype: BoardArchetype
          .values[archIdx.clamp(0, BoardArchetype.values.length - 1)],
      cyanInitialPulsers: cyanPulsers,
      amberInitialPulsers: amberPulsers,
      pulserBurnTicks: pulserBurn,
      burstBurnTicks: burstBurn,
      liveDurationTicks: liveTicks,
      allowPrepPhase: allowPrep,
    );

    for (int i = 0; i < n; i++) {
      final int tIdx = br.readBits(4);
      final int param = br.readBits(4);
      final int gx = br.readBits(6);
      final int gy = br.readBits(6);
      if (tIdx >= NodeType.values.length) {
        throw FormatException('Unknown node type index: $tIdx');
      }
      b.addNode(
        type: NodeType.values[tIdx],
        x: gx / 63.0,
        y: gy / 63.0,
        param: param,
      );
    }

    for (int src = 0; src < n; src++) {
      while (br.readBits(1) == 1) {
        final int dst = br.readBits(6);
        if (dst >= n) {
          throw const FormatException('Edge destination index out of range.');
        }
        int role = PinRole.standard;
        if (b.nodes[dst].type == NodeType.srLatch) {
          role = br.readBits(1) == 1 ? PinRole.reset : PinRole.set;
        }
        b.addOctilinearEdge(src, dst, pinRole: role);
      }
    }

    return b.build();
  }

  /// Validates whether a user-authored Happy Logic Simulator circuit qualifies as a Custom Arena.
  static ({bool ok, String? error}) validateSandboxCircuit(
    ArenaTopology topology,
  ) {
    if (topology.leftRails.isEmpty) {
      return (ok: false, error: 'Custom Arena requires at least 1 Left Rail.');
    }
    if (topology.rightRails.isEmpty) {
      return (ok: false, error: 'Custom Arena requires at least 1 Right Rail.');
    }
    if (topology.busNodes.isEmpty || topology.busNodes.length.isEven) {
      return (
        ok: false,
        error: 'Custom Arena requires an odd number of Central Bus Nodes.',
      );
    }
    final int? cycleDelay = FairnessValidator.computeMinCycleDelay(topology);
    if (cycleDelay != null && cycleDelay < 1) {
      return (ok: false, error: 'Zero-tick combinational loop detected.');
    }
    return (ok: true, error: null);
  }

  static int crc16Ccitt(Uint8List bytes) {
    int crc = 0xFFFF;
    for (final int b in bytes) {
      crc ^= (b & 0xFF) << 8;
      for (int bit = 0; bit < 8; bit++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }
}

final class _BitWriter {
  final List<int> _bytes = <int>[];
  int _bitBuf = 0;
  int _bitCount = 0;

  void writeBits(int value, int width) {
    for (int i = width - 1; i >= 0; i--) {
      _bitBuf = (_bitBuf << 1) | ((value >>> i) & 1);
      _bitCount++;
      if (_bitCount == 8) {
        _bytes.add(_bitBuf & 0xFF);
        _bitBuf = 0;
        _bitCount = 0;
      }
    }
  }

  Uint8List toBytes() {
    if (_bitCount > 0) {
      _bytes.add((_bitBuf << (8 - _bitCount)) & 0xFF);
    }
    return Uint8List.fromList(_bytes);
  }
}

final class _BitReader {
  final Uint8List _bytes;
  final int _limit;
  int _bytePos = 0;
  int _bitOffset = 0;

  _BitReader(this._bytes, this._limit);

  int readBits(int width) {
    int val = 0;
    for (int i = 0; i < width; i++) {
      if (_bytePos >= _limit) {
        throw const FormatException('Unexpected end of bit-stream.');
      }
      final int bit = (_bytes[_bytePos] >>> (7 - _bitOffset)) & 1;
      val = (val << 1) | bit;
      _bitOffset++;
      if (_bitOffset == 8) {
        _bitOffset = 0;
        _bytePos++;
      }
    }
    return val;
  }
}

/// Worldwide seeded Daily "Underdog Transfer" Puzzle builder & shareable summary formatter.
final class DailyUnderdogChallenge {
  static final DateTime _epochUtc = DateTime.utc(2026, 10, 1);

  final int puzzleNumber;
  final String dateIso;
  final ArenaTopology topology;
  final DroidPersona aiPersona;

  const DailyUnderdogChallenge({
    required this.puzzleNumber,
    required this.dateIso,
    required this.topology,
    required this.aiPersona,
  });

  factory DailyUnderdogChallenge.forDate(DateTime date) {
    final DateTime dayUtc = DateTime.utc(date.year, date.month, date.day);
    final int number = dayUtc.difference(_epochUtc).inDays.clamp(1, 99999);
    final String iso =
        '${dayUtc.year.toString().padLeft(4, '0')}-${dayUtc.month.toString().padLeft(2, '0')}-${dayUtc.day.toString().padLeft(2, '0')}';

    final int seedLo =
        Xoshiro128PlusPlus.fnv1a32('HLS-DAILY-$iso'.codeUnits, 0x811C9DC5);
    final int seedHi =
        Xoshiro128PlusPlus.fnv1a32('UNDERDOG-$number'.codeUnits, 0x01000193);

    final ArenaTopology board = ProceduralGenerator.generate(
      seedLo: seedLo,
      seedHi: seedHi,
      archetype: BoardArchetype.underdogAsymmetric,
      busNodeCount: 9,
      cyanPulsers: 3,
      amberPulsers: 6,
      customTitle: 'Daily Underdog #${number.toString().padLeft(3, '0')} ($iso)',
      verifyUnderdog: true,
    );

    return DailyUnderdogChallenge(
      puzzleNumber: number,
      dateIso: iso,
      topology: board,
      aiPersona: DroidPersona.forCode(742),
    );
  }

  /// Formats the GDD compact shareable summary:
  /// `HLS Transfer #042 ⚡ Cyan 7 - 2 Amber (1 Pulser spared)`
  String formatShareSummary({
    required int cyanPoints,
    required int amberPoints,
    required int cyanPulsersSpared,
  }) {
    final String numStr = puzzleNumber.toString().padLeft(3, '0');
    final String icon = cyanPoints > amberPoints ? '⚡' : '💥';
    final String noun = cyanPulsersSpared == 1 ? 'Pulser' : 'Pulsers';
    return 'HLS Transfer #$numStr $icon Cyan $cyanPoints - $amberPoints Amber ($cyanPulsersSpared $noun spared)';
  }
}
