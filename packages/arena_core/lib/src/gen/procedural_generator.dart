import 'dart:math' as math;

import '../math/xoshiro128pp.dart';
import '../sim/arena_topology.dart';
import '../sim/preset_boards.dart';
import '../sim/signal_types.dart';
import 'fairness_validator.dart';

/// Deterministic stratified procedural circuit generator with automatic fairness re-rolling.
abstract final class ProceduralGenerator {
  static ArenaTopology generate({
    required int seedLo,
    int seedHi = 0x517CC1B7,
    BoardArchetype archetype = BoardArchetype.mirrorSymmetric,
    int? busNodeCount,
    int? cyanPulsers,
    int? amberPulsers,
    String? customTitle,
    bool verifyUnderdog = false,
  }) {
    for (int attempt = 0; attempt < 24; attempt++) {
      final Xoshiro128PlusPlus rng = Xoshiro128PlusPlus.fromSeed(
        (seedLo + attempt * 0x9E3779B9) & 0xFFFFFFFF,
        (seedHi ^ (attempt * 0x85EBCA6B)) & 0xFFFFFFFF,
      );

      final ArenaTopology candidate = _synthesizeAttempt(
        rng: rng,
        seedLo: seedLo,
        archetype: archetype,
        busNodeCount: busNodeCount,
        cyanPulsers: cyanPulsers,
        amberPulsers: amberPulsers,
        customTitle: customTitle,
      );

      final FairnessReport report = FairnessValidator.validate(
        candidate,
        verifyUnderdogSolvable:
            verifyUnderdog && archetype == BoardArchetype.underdogAsymmetric,
      );
      if (report.isValid) {
        return candidate;
      }
    }

    // Guaranteed deterministic fallback if extreme custom parameters exhaust 24 re-rolls.
    return PresetBoards.symmetricClassic();
  }

  static ArenaTopology _synthesizeAttempt({
    required Xoshiro128PlusPlus rng,
    required int seedLo,
    required BoardArchetype archetype,
    int? busNodeCount,
    int? cyanPulsers,
    int? amberPulsers,
    String? customTitle,
  }) {
    final int bCount = busNodeCount ??
        (archetype == BoardArchetype.latchHeavy ? 9 : (rng.nextBool(0.55) ? 7 : 9));
    final int oddBusCount = bCount.isOdd ? bCount : bCount + 1;

    final bool isUnderdog = archetype == BoardArchetype.underdogAsymmetric;
    final bool isPointSym = archetype == BoardArchetype.pointSymmetric;
    final bool isLatchHeavy = archetype == BoardArchetype.latchHeavy;
    final bool isPrep = archetype == BoardArchetype.prepHybrid;

    final int cAmmo = cyanPulsers ?? (isUnderdog ? 3 : 5);
    final int aAmmo = amberPulsers ?? (isUnderdog ? 6 : 5);
    final int railCount = isUnderdog ? 5 : rng.nextRange(5, 7);

    final String hexId =
        (seedLo & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
    final ArenaTopologyBuilder b = ArenaTopologyBuilder(
      id: 'proc_${archetype.name}_$hexId',
      title: customTitle ?? 'Sector #$hexId (${_archetypeLabel(archetype)})',
      archetype: archetype,
      cyanInitialPulsers: cAmmo,
      amberInitialPulsers: aAmmo,
      allowPrepPhase: isPrep,
    );

    double mirrorY(double y) => isPointSym ? (1.0 - y) : y;

    // 1. Central Bus column (x = 0.50).
    final int centerIdx = oddBusCount ~/ 2;
    final List<int> busIds = List<int>.generate(oddBusCount, (int idx) {
      final double y = oddBusCount == 1
          ? 0.50
          : 0.12 + idx * (0.76 / (oddBusCount - 1));
      final bool isCore = idx == centerIdx ||
          (oddBusCount >= 9 && (idx == 2 || idx == oddBusCount - 3));
      return b.addNode(
        type: NodeType.busNode,
        x: 0.50,
        y: y,
        param: isCore ? 2 : 1,
      );
    });

    // 2. Outer Input Rails (Col 0 at x=0.06, Col 8 at x=0.94).
    final List<int> cRails = <int>[];
    final List<int> aRails = <int>[];
    final int burstSlot = rng.nextInt(railCount);
    for (int i = 0; i < railCount; i++) {
      final double y = 0.14 + i * (0.72 / (railCount - 1));
      final NodeType rType =
          (i == burstSlot) ? NodeType.burstRail : NodeType.inputRail;
      cRails.add(b.addNode(
        type: rType,
        x: 0.06,
        y: y,
        param: ArenaSide.cyan.code,
      ));
      aRails.add(b.addNode(
        type: isUnderdog ? NodeType.inputRail : rType,
        x: 0.94,
        y: mirrorY(y),
        param: ArenaSide.amber.code,
      ));
    }
    aRails.sort((x, y) => b.nodes[x].y.compareTo(b.nodes[y].y));

    // 3. Entry Layer (Col 1 at x=0.20, Col 7 at x=0.80): Splitters, Buffers, Capacitors, NOT.
    final int entryCount = 4;
    final List<int> cEntry = <int>[];
    final List<int> aEntry = <int>[];
    for (int i = 0; i < entryCount; i++) {
      final double y = 0.18 + i * (0.64 / (entryCount - 1));
      final NodeType cType = _pickEntryType(rng, i, burstSlot, isUnderdog, true);
      final NodeType aType = isUnderdog
          ? _pickEntryType(rng, i, -1, true, false)
          : cType;

      int cParam = 0;
      int aParam = 0;
      if (cType == NodeType.buffer) cParam = rng.nextRange(4, 8);
      if (aType == NodeType.buffer) {
        aParam = isUnderdog ? rng.nextRange(4, 8) : cParam;
      }
      if (cType == NodeType.notGate) cParam = ArenaSide.amber.code;
      if (aType == NodeType.notGate) aParam = ArenaSide.cyan.code;

      cEntry.add(b.addNode(type: cType, x: 0.20, y: y, param: cParam));
      aEntry.add(b.addNode(
        type: aType,
        x: 0.80,
        y: mirrorY(y),
        param: aParam,
      ));
    }

    // 4. Inner Tactical Layer (Col 2/3 at x=0.35, Col 5/6 at x=0.65): Latches, OR, XOR, AND, Clock.
    final int midCount = math.min(6, oddBusCount - 1);
    final List<int> cMid = <int>[];
    final List<int> aMid = <int>[];
    for (int i = 0; i < midCount; i++) {
      final double y = 0.16 + i * (0.68 / (midCount - 1));
      final NodeType cType = _pickMidType(
        rng,
        idx: i,
        isLatchHeavy: isLatchHeavy,
        isUnderdog: isUnderdog,
        forCyan: true,
      );
      final NodeType aType = isUnderdog
          ? _pickMidType(
              rng,
              idx: i,
              isLatchHeavy: isLatchHeavy,
              isUnderdog: true,
              forCyan: false,
            )
          : cType;

      cMid.add(b.addNode(type: cType, x: 0.35, y: y));
      aMid.add(b.addNode(type: aType, x: 0.65, y: mirrorY(y)));
    }

    // Optional symmetric Dead-End hazard when railCount >= 6 (leaves >= 83% rails viable!).
    int? cDead;
    int? aDead;
    if (railCount >= 6 && !isUnderdog && rng.nextBool(0.5)) {
      cDead = b.addNode(type: NodeType.deadEnd, x: 0.22, y: 0.90);
      aDead = b.addNode(type: NodeType.deadEnd, x: 0.78, y: mirrorY(0.90));
    }

    // 5. Wire Rails -> Entry & Mid layers.
    for (int r = 0; r < railCount; r++) {
      if (cDead != null && r == railCount - 1) {
        b.addOctilinearEdge(cRails[r], cDead);
        final int mirrorIdx = isPointSym ? 0 : railCount - 1;
        b.addOctilinearEdge(aRails[mirrorIdx], aDead!);
        continue;
      }

      final int eIdx = (r * entryCount ~/ railCount).clamp(0, entryCount - 1);
      final int mIdx = (r * midCount ~/ railCount).clamp(0, midCount - 1);

      b.addOctilinearEdge(cRails[r], cEntry[eIdx], laneOffset: -0.01 * (r % 2));
      final int aRailNode = isPointSym ? aRails[railCount - 1 - r] : aRails[r];
      b.addOctilinearEdge(aRailNode, aEntry[eIdx], laneOffset: 0.01 * (r % 2));

      // Secondary direct branch so AND/XOR gates receive multiple distinct causal paths.
      if (r.isOdd || isUnderdog) {
        final ({int role}) roleC =
            _pinRoleFor(b.nodes[cMid[mIdx]].type, setPreferred: true);
        final ({int role}) roleA =
            _pinRoleFor(b.nodes[aMid[mIdx]].type, setPreferred: true);
        b.addOctilinearEdge(cRails[r], cMid[mIdx], pinRole: roleC.role);
        b.addOctilinearEdge(aRailNode, aMid[mIdx], pinRole: roleA.role);
      }
    }

    // 6. Wire Entry -> Mid (with Splitter fan-out and cross-court Reset snipes!).
    for (int e = 0; e < entryCount; e++) {
      final int mPrimary = (e * midCount ~/ entryCount).clamp(0, midCount - 1);
      final int mSecondary = (mPrimary + 1) % midCount;

      b.addOctilinearEdge(
        cEntry[e],
        cMid[mPrimary],
        pinRole: _pinRoleFor(b.nodes[cMid[mPrimary]].type, setPreferred: true).role,
      );
      b.addOctilinearEdge(
        aEntry[e],
        aMid[mPrimary],
        pinRole: _pinRoleFor(b.nodes[aMid[mPrimary]].type, setPreferred: true).role,
      );

      final bool isSplitterC = b.nodes[cEntry[e]].type == NodeType.splitter ||
          b.nodes[cEntry[e]].type == NodeType.capacitor;
      final bool isSplitterA = b.nodes[aEntry[e]].type == NodeType.splitter ||
          b.nodes[aEntry[e]].type == NodeType.capacitor;

      if (isSplitterC) {
        b.addOctilinearEdge(
          cEntry[e],
          cMid[mSecondary],
          pinRole: _pinRoleFor(b.nodes[cMid[mSecondary]].type, setPreferred: true).role,
          laneOffset: -0.015,
        );
      }
      if (isSplitterA) {
        b.addOctilinearEdge(
          aEntry[e],
          aMid[mSecondary],
          pinRole: _pinRoleFor(b.nodes[aMid[mSecondary]].type, setPreferred: true).role,
          laneOffset: 0.015,
        );
      }
    }

    // Cross-court tactical interactions: Reset snipes on enemy SR-Latches & XOR/AND cross-feeds!
    for (int m = 0; m < midCount; m++) {
      if (b.nodes[aMid[m]].type == NodeType.srLatch) {
        final int sniperRail = cRails[m % (cDead != null ? railCount - 1 : railCount)];
        b.addOctilinearEdge(
          sniperRail,
          aMid[m],
          pinRole: PinRole.reset,
          laneOffset: -0.025,
        );
      }
      if (b.nodes[cMid[m]].type == NodeType.srLatch) {
        final int sniperIdx = m % (aDead != null ? railCount - 1 : railCount);
        final int sniperRail =
            isPointSym ? aRails[railCount - 1 - sniperIdx] : aRails[sniperIdx];
        b.addOctilinearEdge(
          sniperRail,
          cMid[m],
          pinRole: PinRole.reset,
          laneOffset: 0.025,
        );
      } else if (b.nodes[cMid[m]].type == NodeType.xorGate && m.isEven) {
        // Cross-court XOR choke: enemy entry node can jam/cancel!
        final int oppEntry = aEntry[m % entryCount];
        b.addOctilinearEdge(oppEntry, cMid[m], laneOffset: 0.02);
        b.addOctilinearEdge(cEntry[m % entryCount], aMid[m], laneOffset: -0.02);
      }
    }

    // 7. Wire Mid -> Central Bus ensuring every Bus Node is contested from both halves.
    for (int bIdx = 0; bIdx < oddBusCount; bIdx++) {
      final int mIdx = (bIdx * midCount ~/ oddBusCount).clamp(0, midCount - 1);
      final int aTargetBus = isPointSym ? (oddBusCount - 1 - bIdx) : bIdx;
      b.addOctilinearEdge(cMid[mIdx], busIds[bIdx]);
      b.addOctilinearEdge(aMid[mIdx], busIds[aTargetBus]);

      // Underdog force-multiplier: Cyan latches/splitters claim dual adjacent Bus nodes.
      if (isUnderdog && bIdx + 1 < oddBusCount && bIdx.isEven) {
        b.addOctilinearEdge(cMid[mIdx], busIds[bIdx + 1], laneOffset: -0.012);
      }
    }

    // 8. Optional controlled feedback loop (>= 4-tick Buffer in cycle guarantees stability).
    for (int e = 0; e < entryCount; e++) {
      if (b.nodes[cEntry[e]].type == NodeType.buffer &&
          b.nodes[cEntry[e]].param >= 4 &&
          rng.nextBool(0.45)) {
        final int mIdx = (e * midCount ~/ entryCount).clamp(0, midCount - 1);
        if (b.nodes[cMid[mIdx]].type == NodeType.orGate ||
            b.nodes[cMid[mIdx]].type == NodeType.xorGate) {
          b.addOctilinearEdge(cMid[mIdx], cEntry[e], laneOffset: -0.03);
          if (!isUnderdog &&
              b.nodes[aEntry[e]].type == NodeType.buffer &&
              b.nodes[aEntry[e]].param >= 4) {
            b.addOctilinearEdge(aMid[mIdx], aEntry[e], laneOffset: 0.03);
          }
          break;
        }
      }
    }

    return b.build();
  }

  static NodeType _pickEntryType(
    Xoshiro128PlusPlus rng,
    int slot,
    int burstSlot,
    bool isUnderdog,
    bool forCyan,
  ) {
    if (isUnderdog && forCyan) {
      return slot.isEven ? NodeType.splitter : NodeType.capacitor;
    }
    if (slot == burstSlot % 4) return NodeType.capacitor;
    final int roll = rng.nextInt(10);
    if (roll < 4) return NodeType.splitter;
    if (roll < 7) return NodeType.buffer;
    if (roll < 9) return NodeType.capacitor;
    return NodeType.notGate;
  }

  static NodeType _pickMidType(
    Xoshiro128PlusPlus rng, {
    required int idx,
    required bool isLatchHeavy,
    required bool isUnderdog,
    required bool forCyan,
  }) {
    if (isUnderdog && forCyan && (idx == 1 || idx == 3)) {
      return NodeType.srLatch;
    }
    if (isLatchHeavy && idx.isOdd) {
      return NodeType.srLatch;
    }
    final int roll = rng.nextInt(12);
    if (roll < 3) return NodeType.orGate;
    if (roll < 6) return NodeType.xorGate;
    if (roll < 8) return NodeType.andGate;
    if (roll < 10) return NodeType.srLatch;
    return NodeType.clockOscillator;
  }

  static ({int role}) _pinRoleFor(NodeType type, {required bool setPreferred}) {
    if (type == NodeType.srLatch) {
      return (role: setPreferred ? PinRole.set : PinRole.reset);
    }
    return (role: PinRole.standard);
  }

  static String _archetypeLabel(BoardArchetype archetype) => switch (archetype) {
        BoardArchetype.mirrorSymmetric => 'Symmetric',
        BoardArchetype.pointSymmetric => 'Rotational',
        BoardArchetype.latchHeavy => 'Latch Vaults',
        BoardArchetype.prepHybrid => 'Prep Hybrid',
        BoardArchetype.underdogAsymmetric => 'Underdog Transfer',
      };
}
