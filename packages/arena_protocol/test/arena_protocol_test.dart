import 'package:arena_core/arena_core.dart';
import 'package:arena_protocol/arena_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WireFrameCodec & Lockstep Rollback Convergence', () {
    test('encodes and decodes 4-byte CMD_DEPLOY, EVT_INPUT, and 7-byte HASH_CHECK frames', () {
      final cmd = WireFrameCodec.encodeCmdDeploy(clientTick: 287, railIndex: 4);
      expect(cmd.length, equals(4));
      final decodedCmd = WireFrameCodec.decodeCmdDeploy(cmd);
      expect(decodedCmd.clientTick, equals(287));
      expect(decodedCmd.railIndex, equals(4));

      const ev = ScheduledInputEvent(
        executeTick: 289,
        side: ArenaSide.amber,
        railIndex: 3,
      );
      final bin = ev.toBinaryFrame();
      expect(bin.length, equals(4));
      final decodedEv = ScheduledInputEvent.fromBinaryFrame(bin);
      expect(decodedEv.executeTick, equals(289));
      expect(decodedEv.side, equals(ArenaSide.amber));
      expect(decodedEv.railIndex, equals(3));

      final hc = WireFrameCodec.encodeHashCheck(
        tick: 140,
        stateHash32: 0xDEADBEEF,
      );
      expect(hc.length, equals(7));
      final decodedHc = WireFrameCodec.decodeHashCheck(hc);
      expect(decodedHc.tick, equals(140));
      expect(decodedHc.stateHash32, equals(0xDEADBEEF));
    });

    test('two LockstepSessions under out-of-order & delayed jitter converge to identical FNV-1a hashes', () {
      final topo = PresetBoards.latchVaultDuel();
      final rng = Xoshiro128PlusPlus.fromSeed(42, 99);

      // Generate 40 random authoritative input events across the 300-tick match.
      final allEvents = <ScheduledInputEvent>[];
      for (int i = 0; i < 40; i++) {
        allEvents.add(ScheduledInputEvent(
          executeTick: rng.nextRange(4, 290),
          side: rng.nextBool() ? ArenaSide.cyan : ArenaSide.amber,
          railIndex: rng.nextInt(topo.leftRails.length),
        ));
      }

      final peerCyan = LockstepSession(topo);
      final peerAmber = LockstepSession(topo);

      // Peer Cyan receives events 2 ticks AHEAD of execution;
      // Peer Amber receives them up to 10 ticks LATE (forcing ring-buffer rollback & re-step!).
      for (int t = 0; t < 345; t++) {
        for (final ev in allEvents) {
          if (t == (ev.executeTick - 2).clamp(0, 344)) {
            expect(peerCyan.ingestAuthoritativeEvent(ev), isTrue);
          }
          // Deliver to Amber 9 ticks late, and in reversed order on same tick!
          if (t == (ev.executeTick + 9).clamp(0, 344)) {
            expect(peerAmber.ingestAuthoritativeEvent(ev), isTrue);
          }
        }
        peerCyan.stepTick();
        peerAmber.stepTick();
      }

      expect(peerCyan.liveState.phase, equals(MatchPhase.finished));
      expect(peerAmber.liveState.phase, equals(MatchPhase.finished));
      expect(
        peerCyan.computeStateHash(),
        equals(peerAmber.computeStateHash()),
      );
    });

    test('Pre-Round Gate & Jumper binary frames synchronize two LockstepSessions before Live start', () {
      final cmdGate = WireFrameCodec.encodeCmdPrepGate(
        nodeId: 19,
        newType: NodeType.nandGate,
      );
      expect(cmdGate.length, equals(3));
      final decGate = WireFrameCodec.decodeCmdPrepGate(cmdGate);
      expect(decGate.nodeId, equals(19));
      expect(decGate.newType, equals(NodeType.nandGate));

      final cmdWire = WireFrameCodec.encodeCmdPrepWire(
        srcNode: 7,
        dstNode: 19,
        pinRole: PinRole.reset,
      );
      expect(cmdWire.length, equals(4));
      final decWire = WireFrameCodec.decodeCmdPrepWire(cmdWire);
      expect(decWire.srcNode, equals(7));
      expect(decWire.dstNode, equals(19));
      expect(decWire.pinRole, equals(PinRole.reset));

      final cmdReady = WireFrameCodec.encodeCmdPrepReady(ready: true);
      expect(WireFrameCodec.decodeCmdPrepReady(cmdReady), isTrue);

      final baseTopo = PresetBoards.symmetricClassic();
      final cyanPeer = LockstepSession(
        baseTopo,
        startPhase: MatchPhase.prepPhase,
        initialPhaseTicks: 200,
      );
      final amberPeer = LockstepSession(
        baseTopo,
        startPhase: MatchPhase.prepPhase,
        initialPhaseTicks: 200,
      );

      final int cyanSocket = List<int>.generate(baseTopo.nodeCount, (i) => i)
          .firstWhere((i) => baseTopo.configurableSideOf(i) == ArenaSide.cyan);
      final int amberSocket = List<int>.generate(baseTopo.nodeCount, (i) => i)
          .firstWhere((i) => baseTopo.configurableSideOf(i) == ArenaSide.amber);

      final evCyan = PrepEditEvent.gate(
        side: ArenaSide.cyan,
        nodeId: cyanSocket,
        newType: NodeType.nandGate,
      );
      final evAmber = PrepEditEvent.gate(
        side: ArenaSide.amber,
        nodeId: amberSocket,
        newType: NodeType.xorGate,
      );

      for (final raw in <PrepEditEvent>[evCyan, evAmber]) {
        final decoded = PrepEditEvent.fromBinaryFrame(raw.toBinaryFrame());
        expect(cyanPeer.applyPrepEdit(decoded), isTrue);
        expect(amberPeer.applyPrepEdit(decoded), isTrue);
      }

      cyanPeer.lockInLiveStart();
      amberPeer.lockInLiveStart();

      const deploy0 = ScheduledInputEvent(
        executeTick: 4,
        side: ArenaSide.cyan,
        railIndex: 0,
      );
      cyanPeer.ingestAuthoritativeEvent(deploy0);
      amberPeer.ingestAuthoritativeEvent(deploy0);

      for (int t = 0; t < 40; t++) {
        cyanPeer.stepTick();
        amberPeer.stepTick();
      }
      expect(cyanPeer.computeStateHash(), equals(amberPeer.computeStateHash()));
    });
  });
}
