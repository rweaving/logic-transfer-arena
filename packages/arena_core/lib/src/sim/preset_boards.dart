import 'arena_topology.dart';
import 'signal_types.dart';

/// Curated benchmark and tutorial circuits exercising every Boolean combat rule.
abstract final class PresetBoards {
  /// Balanced 7-Bus symmetric circuit featuring Splitters, OR fast lanes, XOR chokes, and SR-Latches.
  static ArenaTopology symmetricClassic() {
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: 'preset_symmetric_classic',
      title: 'Sector 01: Bus Crossroads',
      archetype: BoardArchetype.mirrorSymmetric,
      cyanInitialPulsers: 5,
      amberInitialPulsers: 5,
    );

    // 7 Central Bus Nodes (index 3 is 2x Core Node).
    final List<int> bus = List<int>.generate(7, (int idx) {
      final double y = 0.14 + idx * 0.12;
      return b.addNode(
        type: NodeType.busNode,
        x: 0.50,
        y: y,
        param: idx == 3 ? 2 : 1,
      );
    });

    // 5 Cyan Left Rails & 5 Amber Right Rails.
    final List<int> cRails = List<int>.generate(5, (int idx) {
      final double y = 0.16 + idx * 0.17;
      return b.addNode(
        type: idx == 2 ? NodeType.burstRail : NodeType.inputRail,
        x: 0.06,
        y: y,
        param: ArenaSide.cyan.code,
      );
    });
    final List<int> aRails = List<int>.generate(5, (int idx) {
      final double y = 0.16 + idx * 0.17;
      return b.addNode(
        type: idx == 2 ? NodeType.burstRail : NodeType.inputRail,
        x: 0.94,
        y: y,
        param: ArenaSide.amber.code,
      );
    });

    // Left mid-board gates.
    final int cSplitTop =
        b.addNode(type: NodeType.splitter, x: 0.20, y: 0.20);
    final int cBufTop =
        b.addNode(type: NodeType.buffer, x: 0.34, y: 0.14, param: 6);
    final int cXorUpper =
        b.addNode(type: NodeType.xorGate, x: 0.36, y: 0.28);
    final int cCapMid =
        b.addNode(type: NodeType.capacitor, x: 0.22, y: 0.50);
    final int cLatchCore =
        b.addNode(type: NodeType.srLatch, x: 0.37, y: 0.46);
    final int cAndLower =
        b.addNode(type: NodeType.andGate, x: 0.34, y: 0.68);
    final int cSplitBot =
        b.addNode(type: NodeType.splitter, x: 0.20, y: 0.80);
    final int cOrBot =
        b.addNode(type: NodeType.orGate, x: 0.36, y: 0.84);

    // Right mirrored mid-board gates.
    final int aSplitTop =
        b.addNode(type: NodeType.splitter, x: 0.80, y: 0.20);
    final int aBufTop =
        b.addNode(type: NodeType.buffer, x: 0.66, y: 0.14, param: 6);
    final int aXorUpper =
        b.addNode(type: NodeType.xorGate, x: 0.64, y: 0.28);
    final int aCapMid =
        b.addNode(type: NodeType.capacitor, x: 0.78, y: 0.50);
    final int aLatchCore =
        b.addNode(type: NodeType.srLatch, x: 0.63, y: 0.54);
    final int aAndLower =
        b.addNode(type: NodeType.andGate, x: 0.66, y: 0.68);
    final int aSplitBot =
        b.addNode(type: NodeType.splitter, x: 0.80, y: 0.80);
    final int aOrBot =
        b.addNode(type: NodeType.orGate, x: 0.64, y: 0.84);

    // Cyan wiring.
    b.addOctilinearEdge(cRails[0], cSplitTop);
    b.addOctilinearEdge(cSplitTop, cBufTop);
    b.addOctilinearEdge(cSplitTop, cXorUpper);
    b.addOctilinearEdge(cRails[1], cXorUpper);
    b.addOctilinearEdge(cRails[1], aLatchCore, pinRole: PinRole.reset, laneOffset: -0.02);

    b.addOctilinearEdge(cRails[2], cCapMid);
    b.addOctilinearEdge(cCapMid, cLatchCore, pinRole: PinRole.set);
    b.addOctilinearEdge(cCapMid, cAndLower);

    b.addOctilinearEdge(cRails[3], cAndLower);
    b.addOctilinearEdge(cRails[4], cSplitBot);
    b.addOctilinearEdge(cSplitBot, cOrBot);
    b.addOctilinearEdge(cSplitBot, bus[5]);

    b.addOctilinearEdge(cBufTop, bus[0]);
    b.addOctilinearEdge(cXorUpper, bus[1]);
    b.addOctilinearEdge(cXorUpper, bus[2]);
    b.addOctilinearEdge(cLatchCore, bus[3]);
    b.addOctilinearEdge(cAndLower, bus[4]);
    b.addOctilinearEdge(cOrBot, bus[6]);

    // Amber mirrored wiring (including cross-courtXOR jam and Reset snipe).
    b.addOctilinearEdge(aRails[0], aSplitTop);
    b.addOctilinearEdge(aSplitTop, aBufTop);
    b.addOctilinearEdge(aSplitTop, aXorUpper);
    b.addOctilinearEdge(aRails[1], aXorUpper);
    b.addOctilinearEdge(aRails[1], cLatchCore, pinRole: PinRole.reset, laneOffset: 0.02);

    b.addOctilinearEdge(aRails[2], aCapMid);
    b.addOctilinearEdge(aCapMid, aLatchCore, pinRole: PinRole.set);
    b.addOctilinearEdge(aCapMid, aAndLower);

    b.addOctilinearEdge(aRails[3], aAndLower);
    b.addOctilinearEdge(aRails[4], aSplitBot);
    b.addOctilinearEdge(aSplitBot, aOrBot);
    b.addOctilinearEdge(aSplitBot, bus[5]);

    b.addOctilinearEdge(aBufTop, bus[0]);
    b.addOctilinearEdge(aXorUpper, bus[1]);
    b.addOctilinearEdge(aXorUpper, bus[2]);
    b.addOctilinearEdge(aLatchCore, bus[3]);
    b.addOctilinearEdge(aAndLower, bus[4]);
    b.addOctilinearEdge(aOrBot, bus[6]);

    return b.build();
  }

  /// Vault-heavy 9-Bus arena centered on SR-Latch capture, Reset snipes, and Clock Oscillators.
  static ArenaTopology latchVaultDuel() {
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: 'preset_latch_vault_duel',
      title: 'Sector 04: Vault Lockout',
      archetype: BoardArchetype.latchHeavy,
      cyanInitialPulsers: 6,
      amberInitialPulsers: 6,
    );

    final List<int> bus = List<int>.generate(9, (int idx) {
      final double y = 0.12 + idx * 0.095;
      final bool isCore = idx == 2 || idx == 4 || idx == 6;
      return b.addNode(
        type: NodeType.busNode,
        x: 0.50,
        y: y,
        param: isCore ? 2 : 1,
      );
    });

    final List<int> cRails = List<int>.generate(6, (int idx) {
      return b.addNode(
        type: idx.isOdd ? NodeType.burstRail : NodeType.inputRail,
        x: 0.06,
        y: 0.14 + idx * 0.144,
        param: ArenaSide.cyan.code,
      );
    });
    final List<int> aRails = List<int>.generate(6, (int idx) {
      return b.addNode(
        type: idx.isOdd ? NodeType.burstRail : NodeType.inputRail,
        x: 0.94,
        y: 0.14 + idx * 0.144,
        param: ArenaSide.amber.code,
      );
    });

    final int cLatch1 = b.addNode(type: NodeType.srLatch, x: 0.35, y: 0.26);
    final int cLatch2 = b.addNode(type: NodeType.srLatch, x: 0.35, y: 0.50);
    final int cLatch3 = b.addNode(type: NodeType.srLatch, x: 0.35, y: 0.74);
    final int cClock =
        b.addNode(type: NodeType.clockOscillator, x: 0.21, y: 0.50);
    final int cNot = b.addNode(
      type: NodeType.notGate,
      x: 0.22,
      y: 0.82,
      param: ArenaSide.amber.code,
    );

    final int aLatch1 = b.addNode(type: NodeType.srLatch, x: 0.65, y: 0.26);
    final int aLatch2 = b.addNode(type: NodeType.srLatch, x: 0.65, y: 0.50);
    final int aLatch3 = b.addNode(type: NodeType.srLatch, x: 0.65, y: 0.74);
    final int aClock =
        b.addNode(type: NodeType.clockOscillator, x: 0.79, y: 0.50);
    final int aNot = b.addNode(
      type: NodeType.notGate,
      x: 0.78,
      y: 0.82,
      param: ArenaSide.cyan.code,
    );

    b.addOctilinearEdge(cRails[0], bus[0]);
    b.addOctilinearEdge(cRails[1], cLatch1, pinRole: PinRole.set);
    b.addOctilinearEdge(cRails[2], aLatch1, pinRole: PinRole.reset);
    b.addOctilinearEdge(cRails[2], cClock);
    b.addOctilinearEdge(cClock, bus[3]);
    b.addOctilinearEdge(cClock, bus[5]);
    b.addOctilinearEdge(cRails[3], cLatch2, pinRole: PinRole.set);
    b.addOctilinearEdge(cRails[4], aLatch2, pinRole: PinRole.reset);
    b.addOctilinearEdge(cRails[4], cLatch3, pinRole: PinRole.set);
    b.addOctilinearEdge(cRails[5], cNot);
    b.addOctilinearEdge(cRails[5], aLatch3, pinRole: PinRole.reset);
    b.addOctilinearEdge(cNot, bus[8]);

    b.addOctilinearEdge(cLatch1, bus[1]);
    b.addOctilinearEdge(cLatch1, bus[2]);
    b.addOctilinearEdge(cLatch2, bus[4]);
    b.addOctilinearEdge(cLatch3, bus[6]);
    b.addOctilinearEdge(cLatch3, bus[7]);

    b.addOctilinearEdge(aRails[0], bus[0]);
    b.addOctilinearEdge(aRails[1], aLatch1, pinRole: PinRole.set);
    b.addOctilinearEdge(aRails[2], cLatch1, pinRole: PinRole.reset);
    b.addOctilinearEdge(aRails[2], aClock);
    b.addOctilinearEdge(aClock, bus[3]);
    b.addOctilinearEdge(aClock, bus[5]);
    b.addOctilinearEdge(aRails[3], aLatch2, pinRole: PinRole.set);
    b.addOctilinearEdge(aRails[4], cLatch2, pinRole: PinRole.reset);
    b.addOctilinearEdge(aRails[4], aLatch3, pinRole: PinRole.set);
    b.addOctilinearEdge(aRails[5], aNot);
    b.addOctilinearEdge(aRails[5], cLatch3, pinRole: PinRole.reset);
    b.addOctilinearEdge(aNot, bus[8]);

    b.addOctilinearEdge(aLatch1, bus[1]);
    b.addOctilinearEdge(aLatch1, bus[2]);
    b.addOctilinearEdge(aLatch2, bus[4]);
    b.addOctilinearEdge(aLatch3, bus[6]);
    b.addOctilinearEdge(aLatch3, bus[7]);

    return b.build();
  }

  /// Tactical cross-wired AND-Hijack & XOR-Counter arena with a Dead-End trap rail.
  static ArenaTopology andHijackGauntlet() {
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: 'preset_and_hijack',
      title: 'Sector 07: Crossfire Hijack',
      archetype: BoardArchetype.prepHybrid,
      cyanInitialPulsers: 5,
      amberInitialPulsers: 5,
      allowPrepPhase: true,
    );

    final List<int> bus = List<int>.generate(7, (int idx) {
      return b.addNode(
        type: NodeType.busNode,
        x: 0.50,
        y: 0.14 + idx * 0.12,
        param: idx == 3 ? 2 : 1,
      );
    });

    final List<int> cRails = List<int>.generate(6, (int idx) {
      return b.addNode(
        type: NodeType.inputRail,
        x: 0.06,
        y: 0.14 + idx * 0.144,
        param: ArenaSide.cyan.code,
      );
    });
    final List<int> aRails = List<int>.generate(6, (int idx) {
      return b.addNode(
        type: NodeType.inputRail,
        x: 0.94,
        y: 0.14 + idx * 0.144,
        param: ArenaSide.amber.code,
      );
    });

    // Shared cross-fed AND gates (whoever fires second hijacks ownership!).
    final int sharedAndTop =
        b.addNode(type: NodeType.andGate, x: 0.42, y: 0.26);
    final int sharedAndMid =
        b.addNode(type: NodeType.andGate, x: 0.58, y: 0.50);
    final int sharedXorBot =
        b.addNode(type: NodeType.xorGate, x: 0.50, y: 0.74);

    final int cDead = b.addNode(type: NodeType.deadEnd, x: 0.22, y: 0.86);
    final int aDead = b.addNode(type: NodeType.deadEnd, x: 0.78, y: 0.14);

    final int cSplit = b.addNode(type: NodeType.splitter, x: 0.24, y: 0.38);
    final int aSplit = b.addNode(type: NodeType.splitter, x: 0.76, y: 0.62);
    final int cBuf =
        b.addNode(type: NodeType.buffer, x: 0.28, y: 0.14, param: 8);
    final int aBuf =
        b.addNode(type: NodeType.buffer, x: 0.72, y: 0.86, param: 8);

    b.addOctilinearEdge(cRails[0], cBuf);
    b.addOctilinearEdge(cBuf, bus[0]);
    b.addOctilinearEdge(cRails[1], sharedAndTop);
    b.addOctilinearEdge(aRails[1], sharedAndTop);
    b.addOctilinearEdge(sharedAndTop, bus[1]);
    b.addOctilinearEdge(sharedAndTop, bus[2]);

    b.addOctilinearEdge(cRails[2], cSplit);
    b.addOctilinearEdge(cSplit, sharedAndMid);
    b.addOctilinearEdge(cSplit, bus[3]);

    b.addOctilinearEdge(aRails[3], aSplit);
    b.addOctilinearEdge(aSplit, sharedAndMid);
    b.addOctilinearEdge(aSplit, bus[3]);
    b.addOctilinearEdge(sharedAndMid, bus[4]);

    b.addOctilinearEdge(cRails[4], sharedXorBot);
    b.addOctilinearEdge(aRails[4], sharedXorBot);
    b.addOctilinearEdge(sharedXorBot, bus[5]);

    // Trap rails (punishes blind spam, mirroring point-symmetric positions).
    b.addOctilinearEdge(cRails[5], cDead);
    b.addOctilinearEdge(aRails[0], aDead);

    b.addOctilinearEdge(cRails[3], bus[6]);
    b.addOctilinearEdge(aRails[5], aBuf);
    b.addOctilinearEdge(aBuf, bus[6]);

    return b.build();
  }
}
