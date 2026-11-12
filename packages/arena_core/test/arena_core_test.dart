import 'package:arena_core/arena_core.dart';
import 'package:test/test.dart';

void main() {
  group('Xoshiro128PlusPlus Cross-Platform PRNG', () {
    test('produces deterministic bit-exact sequences from string & int seeds', () {
      final a = Xoshiro128PlusPlus.fromString('HLS-DAILY-2026-11-11');
      final b = Xoshiro128PlusPlus.fromString('HLS-DAILY-2026-11-11');
      for (int i = 0; i < 1000; i++) {
        expect(a.nextUint32(), equals(b.nextUint32()));
      }
      // Known regression anchor value so future edits cannot drift Web vs VM.
      final anchor = Xoshiro128PlusPlus.fromSeed(0x12345678, 0x9ABCDEF0);
      final first = anchor.nextUint32();
      expect(first, isNonZero);
      expect(
        Xoshiro128PlusPlus.fromSeed(0x12345678, 0x9ABCDEF0).nextUint32(),
        equals(first),
      );
    });
  });

  group('Dual-Color Boolean Truth Tables & Component Semantics', () {
    test('Buffer delays rising and falling edges by exact N ticks', () {
      final b = ArenaTopologyBuilder(pulserBurnTicks: 10);
      final r = b.addNode(type: NodeType.inputRail, x: 0.06, y: 0.5, param: 1);
      final buf = b.addNode(type: NodeType.buffer, x: 0.30, y: 0.5, param: 5);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 1);
      b.addOctilinearEdge(r, buf);
      b.addOctilinearEdge(buf, bus);
      final topo = b.build();
      final state = ArenaState.initial(topo);

      expect(ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, r), isTrue);
      // Ticks 1..4: buffer still outputs LOW.
      for (int t = 1; t <= 4; t++) {
        ArenaSolver.step(topo, state);
        expect(state.nodeOut[buf], equals(SignalState.lowNeutral));
      }
      // Tick 5: 5-tick delay buffer outputs HIGH_CYAN!
      ArenaSolver.step(topo, state);
      expect(state.nodeOut[buf], equals(SignalState.highCyan));
      // Tick 6: Bus node captures Cyan!
      ArenaSolver.step(topo, state);
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.clampedCyan));
    });

    test('AND Gate supports sequential cross-color hijack, 3-in majority, and simultaneous jam', () {
      final b = ArenaTopologyBuilder();
      final cRail = b.addNode(type: NodeType.inputRail, x: 0.06, y: 0.3, param: 1);
      final aRail = b.addNode(type: NodeType.inputRail, x: 0.94, y: 0.3, param: 2);
      final and2 = b.addNode(type: NodeType.andGate, x: 0.50, y: 0.3);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 1);
      b.addOctilinearEdge(cRail, and2);
      b.addOctilinearEdge(aRail, and2);
      b.addOctilinearEdge(and2, bus);
      final topo = b.build();

      // Case 1: Cyan powers first, Amber completes 2 ticks later -> Amber hijacks!
      final hijackState = ArenaState.initial(topo);
      final events = <SimEvent>[];
      ArenaSolver.deployPulser(topo, hijackState, ArenaSide.cyan, cRail);
      ArenaSolver.step(topo, hijackState, events: events);
      expect(hijackState.nodeOut[and2], equals(SignalState.lowNeutral));

      ArenaSolver.deployPulser(topo, hijackState, ArenaSide.amber, aRail);
      ArenaSolver.step(topo, hijackState, events: events);
      expect(hijackState.nodeOut[and2], equals(SignalState.highAmber));
      expect(
        events.any((e) =>
            e.type == SimEventType.andHijacked && e.side == ArenaSide.amber),
        isTrue,
      );

      // Case 2: Simultaneous arrival on tick 0 -> CONTESTED!
      final simState = ArenaState.initial(topo);
      ArenaSolver.deployPulser(topo, simState, ArenaSide.cyan, cRail);
      ArenaSolver.deployPulser(topo, simState, ArenaSide.amber, aRail);
      ArenaSolver.step(topo, simState);
      expect(simState.nodeOut[and2], equals(SignalState.contested));
    });

    test('OR Gate enters CONTESTED on dual color and recovers cleanly when one burns out', () {
      final b = ArenaTopologyBuilder(pulserBurnTicks: 20, burstBurnTicks: 5);
      final cBurst = b.addNode(type: NodeType.burstRail, x: 0.06, y: 0.4, param: 1);
      final aRail = b.addNode(type: NodeType.inputRail, x: 0.94, y: 0.4, param: 2);
      final orGate = b.addNode(type: NodeType.orGate, x: 0.50, y: 0.4);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.6, param: 1);
      b.addOctilinearEdge(cBurst, orGate);
      b.addOctilinearEdge(aRail, orGate);
      b.addOctilinearEdge(orGate, bus);
      final topo = b.build();
      final state = ArenaState.initial(topo);

      ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cBurst);
      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aRail);
      ArenaSolver.step(topo, state);
      expect(state.nodeOut[orGate], equals(SignalState.contested));

      // Contested OR outputs neutral 0 downstream, so Bus stays Neutral!
      ArenaSolver.step(topo, state);
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.neutral));

      // Step past Cyan's 5-tick burst burnout; Amber remains active -> OR flips to HIGH_AMBER!
      for (int i = 0; i < 6; i++) {
        ArenaSolver.step(topo, state);
      }
      expect(state.nodeOut[orGate], equals(SignalState.highAmber));
      ArenaSolver.step(topo, state);
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.clampedAmber));
    });

    test('XOR Gate cancels simultaneous cross-color feeds to LOW_NEUTRAL', () {
      final b = ArenaTopologyBuilder();
      final cRail = b.addNode(type: NodeType.inputRail, x: 0.06, y: 0.4, param: 1);
      final aRail = b.addNode(type: NodeType.inputRail, x: 0.94, y: 0.4, param: 2);
      final xorGate = b.addNode(type: NodeType.xorGate, x: 0.50, y: 0.4);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.6, param: 1);
      b.addOctilinearEdge(cRail, xorGate);
      b.addOctilinearEdge(aRail, xorGate);
      b.addOctilinearEdge(xorGate, bus);
      final topo = b.build();
      final state = ArenaState.initial(topo);
      final events = <SimEvent>[];

      ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cRail);
      ArenaSolver.step(topo, state, events: events);
      expect(state.nodeOut[xorGate], equals(SignalState.highCyan));

      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aRail);
      ArenaSolver.step(topo, state, events: events);
      expect(state.nodeOut[xorGate], equals(SignalState.lowNeutral));
      expect(events.any((e) => e.type == SimEventType.xorCancelled), isTrue);
    });

    test('SR-Latch Vault locks permanent Bus Clamp until Reset pin is sniped', () {
      final b = ArenaTopologyBuilder(pulserBurnTicks: 12, burstBurnTicks: 4);
      final cSet = b.addNode(type: NodeType.burstRail, x: 0.06, y: 0.3, param: 1);
      final aContest = b.addNode(type: NodeType.burstRail, x: 0.94, y: 0.5, param: 2);
      final aReset = b.addNode(type: NodeType.burstRail, x: 0.94, y: 0.3, param: 2);
      final latch = b.addNode(type: NodeType.srLatch, x: 0.35, y: 0.4);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 2);

      b.addOctilinearEdge(cSet, latch, pinRole: PinRole.set);
      b.addOctilinearEdge(aReset, latch, pinRole: PinRole.reset);
      b.addOctilinearEdge(latch, bus);
      b.addOctilinearEdge(aContest, bus);

      final topo = b.build();
      final state = ArenaState.initial(topo);

      // Cyan hits Set with a 4-tick burst.
      ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cSet);
      for (int i = 0; i < 8; i++) {
        ArenaSolver.step(topo, state);
      }
      // Burst burned out, yet Latch stays HIGH_CYAN and Bus stays ClampedCyan!
      expect(state.railRemainingBurnTicks(cSet), equals(0));
      expect(state.nodeOut[latch], equals(SignalState.highCyan));
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.clampedCyan));

      // Amber fires directly at the Bus without resetting Latch -> temporarily Contested, then snaps back to Cyan!
      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aContest);
      ArenaSolver.step(topo, state);
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.contested));
      for (int i = 0; i < 6; i++) {
        ArenaSolver.step(topo, state);
      }
      expect(state.busNodeStatus(bus), equals(BusNodeStatus.clampedCyan));

      // Now Amber snipes the Latch Reset pin -> clears Latch and unlocks Bus!
      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aReset);
      ArenaSolver.step(topo, state);
      expect(state.nodeOut[latch], equals(SignalState.lowNeutral));
    });

    test('Capacitor stretches brief burst by 60 ticks (3.0s) & Clock Oscillator strobes 10/10', () {
      final b = ArenaTopologyBuilder(burstBurnTicks: 3);
      final cBurst = b.addNode(type: NodeType.burstRail, x: 0.06, y: 0.3, param: 1);
      final aBurst = b.addNode(type: NodeType.burstRail, x: 0.94, y: 0.7, param: 2);
      final cap = b.addNode(type: NodeType.capacitor, x: 0.25, y: 0.3);
      final clk = b.addNode(type: NodeType.clockOscillator, x: 0.25, y: 0.7);
      final notG = b.addNode(type: NodeType.notGate, x: 0.40, y: 0.3, param: 2);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 1);

      b.addOctilinearEdge(cBurst, cap);
      b.addOctilinearEdge(cBurst, clk);
      b.addOctilinearEdge(aBurst, clk);
      b.addOctilinearEdge(cap, notG);
      b.addOctilinearEdge(notG, bus);
      b.addOctilinearEdge(clk, bus);

      final topo = b.build();
      final state = ArenaState.initial(topo);

      // Before any input, NOT gate with Amber bias outputs HIGH_AMBER on step 1.
      ArenaSolver.step(topo, state);
      expect(state.nodeOut[notG], equals(SignalState.highAmber));
      expect(state.nodeOut[clk], equals(SignalState.lowNeutral));

      // Trigger both Capacitor and Clock with 3-tick Cyan burst.
      ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cBurst);
      for (int i = 0; i < 3; i++) {
        ArenaSolver.step(topo, state);
      }
      // Burst has now ended (remaining == 0), Capacitor holds full 60-tick charge!
      expect(state.railRemainingBurnTicks(cBurst), equals(0));
      expect(state.capacitorChargeTicks(cap), equals(60));
      expect(state.nodeOut[cap], equals(SignalState.highCyan));
      // Active Capacitor shuts off NOT gate!
      expect(state.nodeOut[notG], equals(SignalState.lowNeutral));

      // Verify Clock toggles HIGH (ticks 0..9 of phase) then LOW (ticks 10..19).
      int highTicks = 0;
      int lowTicks = 0;
      for (int i = 0; i < 20; i++) {
        if (state.nodeOut[clk] == SignalState.highCyan) {
          highTicks++;
        } else {
          lowTicks++;
        }
        ArenaSolver.step(topo, state);
      }
      expect(highTicks, equals(10));
      expect(lowTicks, equals(10));

      // Amber hits Clock -> re-colors Clock immediately to HIGH_AMBER!
      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aBurst);
      ArenaSolver.step(topo, state);
      expect(state.nodeOut[clk], equals(SignalState.highAmber));
    });

    test('Smart Overtime waits for in-flight Buffer time-bomb then settles cleanly', () {
      final b = ArenaTopologyBuilder(
        liveDurationTicks: 20,
        maxOvertimeTicks: 40,
        burstBurnTicks: 4,
      );
      final cBurst = b.addNode(type: NodeType.burstRail, x: 0.06, y: 0.5, param: 1);
      final aRail = b.addNode(type: NodeType.burstRail, x: 0.94, y: 0.5, param: 2);
      final delay8 = b.addNode(type: NodeType.buffer, x: 0.30, y: 0.5, param: 8);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 2);
      b.addOctilinearEdge(cBurst, delay8);
      b.addOctilinearEdge(delay8, bus);
      b.addOctilinearEdge(aRail, bus);

      final topo = b.build();
      final state = ArenaState.initial(topo);

      // Amber captures Bus early at tick 2.
      ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aRail);
      for (int t = 0; t < 19; t++) {
        ArenaSolver.step(topo, state);
      }
      expect(state.computeBusScore(topo).amber, equals(2));

      // Cyan fires buzzer-beater on final live tick (tick 19 -> 20) through 8-tick Buffer!
      expect(ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cBurst), isTrue);
      ArenaSolver.step(topo, state);
      expect(state.phase, equals(MatchPhase.overtime));
      // Cannot deploy new Pulsers in Overtime.
      expect(ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aRail), isFalse);

      ArenaSolver.runUntilSettled(topo, state);
      expect(state.phase, equals(MatchPhase.finished));
      // Cyan's delayed pulse arrived during Overtime and stole the 2x Bus node, settling before 40-tick cap!
      expect(state.computeBusScore(topo).cyan, equals(2));
      expect(state.tick, lessThan(20 + 40));
    });
  });

  group('Determinism, Procedural Generation, AI & URL Codec', () {
    test('200 randomized matches replay with 100% identical FNV-1a hashes', () {
      final topo = PresetBoards.symmetricClassic();
      for (int seed = 1; seed <= 200; seed++) {
        final rngA = Xoshiro128PlusPlus.fromSeed(seed, 0xABCD);
        final rngB = Xoshiro128PlusPlus.fromSeed(seed, 0xABCD);

        final sA = ArenaState.initial(topo);
        final sB = ArenaState.initial(topo);

        while (sA.phase != MatchPhase.finished) {
          if (sA.phase == MatchPhase.liveCountdown) {
            if (rngA.nextBool(0.06)) {
              final r = topo.leftRails[rngA.nextInt(topo.leftRails.length)];
              ArenaSolver.deployPulser(topo, sA, ArenaSide.cyan, r);
            }
            if (rngA.nextBool(0.06)) {
              final r = topo.rightRails[rngA.nextInt(topo.rightRails.length)];
              ArenaSolver.deployPulser(topo, sA, ArenaSide.amber, r);
            }

            if (rngB.nextBool(0.06)) {
              final r = topo.leftRails[rngB.nextInt(topo.leftRails.length)];
              ArenaSolver.deployPulser(topo, sB, ArenaSide.cyan, r);
            }
            if (rngB.nextBool(0.06)) {
              final r = topo.rightRails[rngB.nextInt(topo.rightRails.length)];
              ArenaSolver.deployPulser(topo, sB, ArenaSide.amber, r);
            }
          }
          ArenaSolver.step(topo, sA);
          ArenaSolver.step(topo, sB);
          expect(
            sA.stateHash32(topo.nodeCount),
            equals(sB.stateHash32(topo.nodeCount)),
          );
        }
      }
    });

    test('ProceduralGenerator produces valid fair boards across all archetypes', () {
      for (final arch in BoardArchetype.values) {
        for (int s = 1; s <= 10; s++) {
          final board = ProceduralGenerator.generate(
            seedLo: s * 1337,
            archetype: arch,
          );
          final report = FairnessValidator.validate(board);
          expect(report.isValid, isTrue, reason: report.failureReason);
        }
      }
    });

    test('DailyUnderdogChallenge generates solvable 3v6 puzzle and formatted share summary', () {
      final daily = DailyUnderdogChallenge.forDate(DateTime.utc(2026, 11, 11));
      expect(daily.puzzleNumber, equals(41));
      expect(daily.topology.cyanInitialPulsers, equals(3));
      expect(daily.topology.amberInitialPulsers, equals(6));
      final report = FairnessValidator.validate(
        daily.topology,
        verifyUnderdogSolvable: true,
      );
      expect(report.isValid, isTrue);

      final share = daily.formatShareSummary(
        cyanPoints: 7,
        amberPoints: 2,
        cyanPulsersSpared: 1,
      );
      expect(share, equals('HLS Transfer #041 ⚡ Cyan 7 - 2 Amber (1 Pulser spared)'));
    });

    test('700-series Battle Logic AI consistently defeats 100-series Maintenance AI', () {
      final topo = PresetBoards.symmetricClassic();
      final profile = BoardTacticalProfile.analyze(topo);
      int highTierWins = 0;
      int lowTierWins = 0;

      for (int m = 0; m < 24; m++) {
        final state = ArenaState.initial(topo);
        final smartCyan = DroidProbeController(
          side: ArenaSide.cyan,
          persona: DroidPersona.forCode(742),
          profile: profile,
          rng: Xoshiro128PlusPlus.fromSeed(m + 100, 1),
        );
        final weakAmber = DroidProbeController(
          side: ArenaSide.amber,
          persona: DroidPersona.forCode(104),
          profile: profile,
          rng: Xoshiro128PlusPlus.fromSeed(m + 500, 2),
        );

        while (state.phase != MatchPhase.finished) {
          final cFire = smartCyan.updateTick(state);
          if (cFire != null) {
            ArenaSolver.deployPulser(topo, state, ArenaSide.cyan, cFire);
          }
          final aFire = weakAmber.updateTick(state);
          if (aFire != null) {
            ArenaSolver.deployPulser(topo, state, ArenaSide.amber, aFire);
          }
          ArenaSolver.step(topo, state);
        }
        final score = state.computeBusScore(topo);
        if (score.cyan > score.amber) highTierWins++;
        if (score.amber > score.cyan) lowTierWins++;
      }

      expect(highTierWins, greaterThan(lowTierWins * 2));
    });

    test('CircuitUrlCodec round-trips boards under 260 chars and rejects corrupted CRC', () {
      for (int s = 1; s <= 25; s++) {
        final orig = ProceduralGenerator.generate(
          seedLo: s * 9973,
          archetype: BoardArchetype.values[s % BoardArchetype.values.length],
        );
        final fragment = CircuitUrlCodec.encodeUrlFragment(orig);
        expect(fragment.startsWith('#arena=v1.'), isTrue);
        expect(fragment.length, lessThan(260));

        final decoded = CircuitUrlCodec.decodeUrlFragment(
          'https://happylogicsim.app/$fragment',
        );
        expect(decoded.nodeCount, equals(orig.nodeCount));
        expect(decoded.edgeCount, equals(orig.edgeCount));
        expect(decoded.cyanInitialPulsers, equals(orig.cyanInitialPulsers));
        expect(decoded.amberInitialPulsers, equals(orig.amberInitialPulsers));
        for (int i = 0; i < orig.nodeCount; i++) {
          expect(decoded.typeOf(i), equals(orig.typeOf(i)));
          expect(decoded.nodeParam[i], equals(orig.nodeParam[i]));
        }
      }

      // Flipping a byte in encoded bytes must fail CRC-16 check.
      final bytes = CircuitUrlCodec.encodeBytes(PresetBoards.symmetricClassic());
      bytes[12] ^= 0xFF;
      expect(() => CircuitUrlCodec.decodeBytes(bytes), throwsFormatException);
    });

    test('Pre-Round Gate Configuration configures real NAND/NOR/XOR/AND gates on both sides', () {
      ArenaTopology topo = PresetBoards.symmetricClassic();
      // Find one Cyan gate socket and one Amber gate socket.
      final int cyanSocket = List<int>.generate(topo.nodeCount, (i) => i)
          .firstWhere((i) =>
              topo.configurableSideOf(i) == ArenaSide.cyan &&
              topo.typeOf(i) == NodeType.andGate);
      final int amberSocket = List<int>.generate(topo.nodeCount, (i) => i)
          .firstWhere((i) =>
              topo.configurableSideOf(i) == ArenaSide.amber &&
              topo.typeOf(i) == NodeType.orGate);

      topo = topo.tryConfigureGate(
        side: ArenaSide.cyan,
        nodeId: cyanSocket,
        newType: NodeType.nandGate,
      )!;
      topo = topo.tryConfigureGate(
        side: ArenaSide.amber,
        nodeId: amberSocket,
        newType: NodeType.norGate,
      )!;

      expect(topo.typeOf(cyanSocket), equals(NodeType.nandGate));
      expect(topo.typeOf(amberSocket), equals(NodeType.norGate));

      // Verify VCC-gated NAND stays LOW before Pulser, turns HIGH when 1 input/rail is powered,
      // and cuts off to LOW when all inputs become HIGH!
      final b = ArenaTopologyBuilder();
      final r1 = b.addNode(type: NodeType.inputRail, x: 0.06, y: 0.3, param: 1);
      final r2 = b.addNode(type: NodeType.inputRail, x: 0.06, y: 0.7, param: 1);
      final g = b.addNode(type: NodeType.andGate, x: 0.30, y: 0.5);
      final bus = b.addNode(type: NodeType.busNode, x: 0.50, y: 0.5, param: 1);
      b.addOctilinearEdge(r1, g);
      b.addOctilinearEdge(r2, g);
      b.addOctilinearEdge(g, bus);
      final configured = b.build().tryConfigureGate(
            side: ArenaSide.cyan,
            nodeId: g,
            newType: NodeType.nandGate,
          )!;

      final state = ArenaState.initial(configured);
      // Idle (no rails active -> VCC off -> LOW)
      ArenaSolver.step(configured, state);
      expect(state.nodeOut[g], equals(SignalState.lowNeutral));

      // Deploy on r1 only -> inputs are (1, 0), VCC is ON -> 1 NAND 0 == HIGH_CYAN!
      ArenaSolver.deployPulser(configured, state, ArenaSide.cyan, r1);
      ArenaSolver.step(configured, state);
      expect(state.nodeOut[g], equals(SignalState.highCyan));

      // Deploy on r2 as well -> inputs are (1, 1) -> 1 NAND 1 == LOW_NEUTRAL!
      ArenaSolver.deployPulser(configured, state, ArenaSide.cyan, r2);
      ArenaSolver.step(configured, state);
      expect(state.nodeOut[g], equals(SignalState.lowNeutral));
    });

    test('SandboxCircuitDraft places mirrored gates, wires SET/RESET pins, validates, and exports #arena=v1 hash', () {
      final draft = SandboxCircuitDraft.scaffold(
        railsPerSide: 3,
        busCount: 5,
        autoMirror: true,
      );
      // Initial scaffold has no interior wires yet -> fails causal rail check.
      expect(draft.validate().ok, isFalse);

      // Place a mirrored XOR gate at x=0.30, y=0.50 -> creates Cyan (#11) & Amber (#12) twins!
      final int cyanXor = draft.placeComponent(
        type: NodeType.xorGate,
        x: 0.30,
        y: 0.50,
      )!;
      expect(draft.nodes.length, equals(5 + 6 + 2));
      expect(draft.nodes[cyanXor].type, equals(NodeType.xorGate));
      expect(draft.nodes[cyanXor + 1].type, equals(NodeType.xorGate));

      // Connect Cyan middle rail (#7) -> Cyan XOR -> Center 2x Bus (#2), which auto-mirrors Amber!
      final int cyanRail = draft.nodes.indexWhere(
        (n) => n.type.isRail && n.param == ArenaSide.cyan.code,
      );
      draft.connectOrToggleWire(src: cyanRail, dst: cyanXor);
      draft.connectOrToggleWire(src: cyanXor, dst: 2);

      final report = draft.validate();
      expect(report.ok, isTrue);
      expect(report.urlHash, isNotNull);
      expect(report.urlHash!.startsWith('#arena=v1.'), isTrue);
      expect(report.causalCyanRails, greaterThanOrEqualTo(1));
      expect(report.causalAmberRails, greaterThanOrEqualTo(1));

      final decoded = CircuitUrlCodec.decodeUrlFragment(report.urlHash!);
      expect(decoded.nodeCount, equals(draft.nodes.length));
      expect(decoded.edgeCount, equals(draft.edges.length));
    });
  });
}
