import 'dart:typed_data';

import 'arena_state.dart';
import 'arena_topology.dart';
import 'signal_types.dart';

/// Deterministic 20Hz (`50ms`/tick) synchronous Jacobi Boolean combat solver.
abstract final class ArenaSolver {
  /// Deploys a Pulser onto [railNodeId] for [side]. Returns `true` if accepted.
  static bool deployPulser(
    ArenaTopology topology,
    ArenaState state,
    ArenaSide side,
    int railNodeId, {
    List<SimEvent>? events,
  }) {
    if (!state.canDeployOnRail(topology, side, railNodeId)) {
      return false;
    }

    if (side == ArenaSide.cyan) {
      state.cyanPulsersRemaining--;
    } else {
      state.amberPulsersRemaining--;
    }

    final int burnTicks = topology.typeOf(railNodeId) == NodeType.burstRail
        ? topology.burstBurnTicks
        : topology.pulserBurnTicks;

    state.nodeInternal[railNodeId] = (side.code & 0x3) | (burnTicks << 2);
    state.nodeOut[railNodeId] = side.signal;

    events?.add(SimEvent(
      tick: state.tick,
      type: SimEventType.pulserDeployed,
      nodeId: railNodeId,
      side: side,
    ));
    return true;
  }

  /// Advances the match state by exactly 1 simulation tick (`50ms`).
  static void step(
    ArenaTopology topology,
    ArenaState state, {
    List<SimEvent>? events,
  }) {
    switch (state.phase) {
      case MatchPhase.finished:
        return;

      case MatchPhase.coinFlip:
        state.tick++;
        state.phaseTicksRemaining--;
        if (state.phaseTicksRemaining <= 0) {
          if (topology.allowPrepPhase) {
            state.phase = MatchPhase.prepPhase;
            state.phaseTicksRemaining = 100; // 5.0s @ 20Hz
          } else {
            state.phase = MatchPhase.liveCountdown;
            state.phaseTicksRemaining = topology.liveDurationTicks;
          }
        }
        return;

      case MatchPhase.prepPhase:
        state.tick++;
        state.phaseTicksRemaining--;
        if (state.phaseTicksRemaining <= 0) {
          state.phase = MatchPhase.liveCountdown;
          state.phaseTicksRemaining = topology.liveDurationTicks;
        }
        return;

      case MatchPhase.liveCountdown:
      case MatchPhase.overtime:
        break;
    }

    final int n = topology.nodeCount;
    final Uint8List types = topology.nodeType;
    final Uint8List params = topology.nodeParam;
    final Uint16List inStart = topology.inEdgeStart;
    final Uint8List inSrc = topology.inEdgeSrc;
    final Uint8List inRole = topology.inEdgeRole;

    final Uint8List curOut = state.nodeOut;
    final Uint8List nextOut = state.scratchOut;
    final Uint32List internal = state.nodeInternal;

    // Lazy dynamic board bias if any NOT/NAND/NOR gate has param == 0.
    int? dynamicBiasCache;

    // CMOS rail supply check for player-configured inverting gates (bit 0x08).
    bool cyanVccActive = false;
    for (int r = 0; r < topology.leftRails.length; r++) {
      if (curOut[topology.leftRails[r]] == SignalState.highCyan) {
        cyanVccActive = true;
        break;
      }
    }
    bool amberVccActive = false;
    for (int r = 0; r < topology.rightRails.length; r++) {
      if (curOut[topology.rightRails[r]] == SignalState.highAmber) {
        amberVccActive = true;
        break;
      }
    }

    int resolveInverterSupply(int nodeIdx, int rawParam) {
      final bool vccGated = (rawParam & 0x08) != 0;
      int bias = rawParam & 0x07;
      if (bias != SignalState.highCyan && bias != SignalState.highAmber) {
        final double nx = topology.nodeX[nodeIdx];
        if (nx < 0.48) {
          bias = SignalState.highCyan;
        } else if (nx > 0.52) {
          bias = SignalState.highAmber;
        } else {
          dynamicBiasCache ??= _computeDynamicBias(topology, state);
          bias = dynamicBiasCache!;
        }
      }
      if (vccGated) {
        final bool powered = bias == SignalState.highCyan
            ? cyanVccActive
            : (bias == SignalState.highAmber ? amberVccActive : false);
        if (!powered) return SignalState.lowNeutral;
      }
      return bias;
    }

    for (int i = 0; i < n; i++) {
      final int word = internal[i];
      final NodeType type = NodeType.values[types[i]];

      switch (type) {
        case NodeType.inputRail:
        case NodeType.burstRail:
          final int owner = word & 0x3;
          final int rem = (word >>> 2) & 0x3FF;
          final int cool = (word >>> 12) & 0xFF;
          if (rem > 0) {
            final int nextRem = rem - 1;
            if (nextRem == 0) {
              nextOut[i] = SignalState.lowNeutral;
              internal[i] = (topology.railCooldownTicks & 0xFF) << 12;
              events?.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.pulserBurnedOut,
                nodeId: i,
                side: ArenaSide.fromCode(owner),
              ));
            } else {
              nextOut[i] = owner;
              internal[i] = owner | (nextRem << 2);
            }
          } else if (cool > 0) {
            nextOut[i] = SignalState.lowNeutral;
            internal[i] = (cool - 1) << 12;
          } else {
            nextOut[i] = SignalState.lowNeutral;
            internal[i] = 0;
          }

        case NodeType.buffer:
          int delay = params[i];
          if (delay < 1) delay = 1;
          if (delay > 16) delay = 16;
          final int inSig = _mergeStandardInputs(
            i,
            inStart,
            inSrc,
            curOut,
          );
          final int nextReg = ((word << 2) | (inSig & 0x3)) & 0xFFFFFFFF;
          internal[i] = nextReg;
          nextOut[i] = (nextReg >>> ((delay - 1) * 2)) & 0x3;

        case NodeType.splitter:
          nextOut[i] = _mergeStandardInputs(i, inStart, inSrc, curOut);

        case NodeType.notGate:
        case NodeType.norGate:
          final int supply = resolveInverterSupply(i, params[i]);
          bool anyHigh = false;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan || sig == SignalState.highAmber) {
              anyHigh = true;
              break;
            }
          }
          nextOut[i] = anyHigh ? SignalState.lowNeutral : supply;

        case NodeType.nandGate:
          final int supply = resolveInverterSupply(i, params[i]);
          final int s = inStart[i];
          final int end = inStart[i + 1];
          bool allHigh = end > s;
          for (int e = s; e < end; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig != SignalState.highCyan && sig != SignalState.highAmber) {
              allHigh = false;
              break;
            }
          }
          nextOut[i] = allHigh ? SignalState.lowNeutral : supply;

        case NodeType.andGate:
          final int s = inStart[i];
          final int end = inStart[i + 1];
          final int totalIn = end - s;
          if (totalIn == 0) {
            nextOut[i] = SignalState.lowNeutral;
            internal[i] = 0;
            break;
          }
          final int prevCompleter = word & 0x3;
          final int prevMask = word >>> 2;

          int cyanCount = 0;
          int amberCount = 0;
          int nonHighCount = 0;
          int newlyCyan = 0;
          int newlyAmber = 0;
          int curMask = 0;

          for (int e = s; e < end; e++) {
            final int k = e - s;
            final int sig = curOut[inSrc[e]];
            if (k < 8) {
              curMask |= (sig & 0x3) << (k * 2);
            }
            final int prevSig = k < 8 ? ((prevMask >>> (k * 2)) & 0x3) : 0;
            final bool wasHigh = prevSig == SignalState.highCyan ||
                prevSig == SignalState.highAmber;

            if (sig == SignalState.highCyan) {
              cyanCount++;
              if (!wasHigh) newlyCyan++;
            } else if (sig == SignalState.highAmber) {
              amberCount++;
              if (!wasHigh) newlyAmber++;
            } else {
              nonHighCount++;
            }
          }

          if (nonHighCount > 0) {
            nextOut[i] = SignalState.lowNeutral;
            internal[i] = curMask << 2;
          } else {
            int winner;
            if (cyanCount > amberCount) {
              winner = SignalState.highCyan;
            } else if (amberCount > cyanCount) {
              winner = SignalState.highAmber;
            } else if (prevCompleter == SignalState.highCyan ||
                prevCompleter == SignalState.highAmber) {
              winner = prevCompleter;
            } else if (newlyCyan > 0 && newlyAmber == 0) {
              winner = SignalState.highCyan;
            } else if (newlyAmber > 0 && newlyCyan == 0) {
              winner = SignalState.highAmber;
            } else {
              winner = SignalState.contested;
            }

            if (events != null &&
                prevCompleter == 0 &&
                cyanCount > 0 &&
                amberCount > 0 &&
                SignalState.isHigh(winner)) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.andHijacked,
                nodeId: i,
                side: SignalState.ownerOf(winner),
              ));
            }

            final int storedCompleter = SignalState.isHigh(winner) ? winner : 0;
            nextOut[i] = winner;
            internal[i] = storedCompleter | (curMask << 2);
          }

        case NodeType.orGate:
          int cyanCount = 0;
          int amberCount = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan) {
              cyanCount++;
            } else if (sig == SignalState.highAmber) {
              amberCount++;
            }
          }
          if (cyanCount > 0 && amberCount == 0) {
            nextOut[i] = SignalState.highCyan;
          } else if (amberCount > 0 && cyanCount == 0) {
            nextOut[i] = SignalState.highAmber;
          } else if (cyanCount > 0 && amberCount > 0) {
            nextOut[i] = SignalState.contested;
            if (events != null && curOut[i] != SignalState.contested) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.orContested,
                nodeId: i,
              ));
            }
          } else {
            nextOut[i] = SignalState.lowNeutral;
          }

        case NodeType.xorGate:
          int cyanCount = 0;
          int amberCount = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan) {
              cyanCount++;
            } else if (sig == SignalState.highAmber) {
              amberCount++;
            }
          }
          final int active = cyanCount + amberCount;
          if (active == 1) {
            nextOut[i] = cyanCount == 1
                ? SignalState.highCyan
                : SignalState.highAmber;
            internal[i] = 0;
          } else {
            nextOut[i] = SignalState.lowNeutral;
            final bool crossCancel = cyanCount > 0 && amberCount > 0;
            if (crossCancel && word == 0 && events != null) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.xorCancelled,
                nodeId: i,
              ));
            }
            internal[i] = crossCancel ? 1 : 0;
          }

        case NodeType.srLatch:
          int stored = word & 0x3;
          bool resetActive = false;
          int setCyan = 0;
          int setAmber = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            final int role = inRole[e];
            if (role == PinRole.reset) {
              if (sig == SignalState.highCyan ||
                  sig == SignalState.highAmber) {
                resetActive = true;
              }
            } else {
              if (sig == SignalState.highCyan) {
                setCyan++;
              } else if (sig == SignalState.highAmber) {
                setAmber++;
              }
            }
          }
          if (resetActive) {
            if (stored != 0 && events != null) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.latchReset,
                nodeId: i,
              ));
            }
            stored = 0;
          } else if (setCyan > 0 && setAmber == 0) {
            if (stored != SignalState.highCyan && events != null) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.latchLocked,
                nodeId: i,
                side: ArenaSide.cyan,
              ));
            }
            stored = SignalState.highCyan;
          } else if (setAmber > 0 && setCyan == 0) {
            if (stored != SignalState.highAmber && events != null) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.latchLocked,
                nodeId: i,
                side: ArenaSide.amber,
              ));
            }
            stored = SignalState.highAmber;
          }
          internal[i] = stored;
          nextOut[i] = stored;

        case NodeType.capacitor:
          int owner = word & 0x3;
          int charge = (word >>> 2) & 0x3FF;
          int cyanCount = 0;
          int amberCount = 0;
          int contestedCount = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan) {
              cyanCount++;
            } else if (sig == SignalState.highAmber) {
              amberCount++;
            } else if (sig == SignalState.contested) {
              contestedCount++;
            }
          }

          if (cyanCount > 0 && amberCount == 0 && contestedCount == 0) {
            owner = SignalState.highCyan;
            charge = 60; // 3.0s @ 20Hz
            nextOut[i] = SignalState.highCyan;
          } else if (amberCount > 0 && cyanCount == 0 && contestedCount == 0) {
            owner = SignalState.highAmber;
            charge = 60;
            nextOut[i] = SignalState.highAmber;
          } else if ((cyanCount > 0 && amberCount > 0) || contestedCount > 0) {
            charge = charge > 4 ? charge - 4 : 0;
            if (charge == 0) {
              owner = 0;
              nextOut[i] = SignalState.contested;
            } else {
              nextOut[i] = owner;
            }
          } else {
            if (charge > 0) {
              nextOut[i] = owner;
              charge--;
              if (charge == 0) {
                owner = 0;
              }
            } else {
              owner = 0;
              nextOut[i] = SignalState.lowNeutral;
            }
          }
          internal[i] = (owner & 0x3) | (charge << 2);

        case NodeType.clockOscillator:
          int owner = word & 0x3;
          int awake = (word >>> 2) & 0x1;
          int phase = (word >>> 3) & 0xFF;

          int cyanCount = 0;
          int amberCount = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan) {
              cyanCount++;
            } else if (sig == SignalState.highAmber) {
              amberCount++;
            }
          }

          int trigOwner = 0;
          if (cyanCount > 0 && amberCount == 0) {
            trigOwner = SignalState.highCyan;
          } else if (amberCount > 0 && cyanCount == 0) {
            trigOwner = SignalState.highAmber;
          }

          if (trigOwner != 0 && (awake == 0 || owner != trigOwner)) {
            awake = 1;
            owner = trigOwner;
            phase = 0;
            events?.add(SimEvent(
              tick: state.tick + 1,
              type: SimEventType.clockAwakened,
              nodeId: i,
              side: ArenaSide.fromCode(trigOwner),
            ));
          }

          if (awake == 1) {
            nextOut[i] = phase < 10 ? owner : SignalState.lowNeutral;
            phase = (phase + 1) % 20;
          } else {
            nextOut[i] = SignalState.lowNeutral;
          }
          internal[i] = (owner & 0x3) | (awake << 2) | (phase << 3);

        case NodeType.deadEnd:
          bool anyHigh = false;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            if (SignalState.isHigh(curOut[inSrc[e]])) {
              anyHigh = true;
              break;
            }
          }
          if (anyHigh && (word & 0x1) == 0 && events != null) {
            events.add(SimEvent(
              tick: state.tick + 1,
              type: SimEventType.deadEndFizzle,
              nodeId: i,
            ));
          }
          internal[i] = anyHigh ? 1 : 0;
          nextOut[i] = SignalState.lowNeutral;

        case NodeType.busNode:
          final int prevOwner = word & 0x3;
          final bool wasContested = ((word >>> 3) & 0x1) != 0;

          int cyanPower = 0;
          int amberPower = 0;
          for (int e = inStart[i]; e < inStart[i + 1]; e++) {
            final int sig = curOut[inSrc[e]];
            if (sig == SignalState.highCyan) {
              cyanPower++;
            } else if (sig == SignalState.highAmber) {
              amberPower++;
            }
          }

          int nextOwner = prevOwner;
          int clamped = 0;
          int contested = 0;
          int outSig = SignalState.lowNeutral;

          if (cyanPower > amberPower) {
            nextOwner = SignalState.highCyan;
            clamped = 1;
            contested = 0;
            outSig = SignalState.highCyan;
            if (events != null &&
                (prevOwner != SignalState.highCyan || wasContested)) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.busCaptured,
                nodeId: i,
                side: ArenaSide.cyan,
              ));
            }
          } else if (amberPower > cyanPower) {
            nextOwner = SignalState.highAmber;
            clamped = 1;
            contested = 0;
            outSig = SignalState.highAmber;
            if (events != null &&
                (prevOwner != SignalState.highAmber || wasContested)) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.busCaptured,
                nodeId: i,
                side: ArenaSide.amber,
              ));
            }
          } else if (cyanPower > 0) {
            // Equal non-zero power collides into Contested state and strips prior soft hold.
            nextOwner = 0;
            clamped = 0;
            contested = 1;
            outSig = SignalState.contested;
            if (events != null && !wasContested) {
              events.add(SimEvent(
                tick: state.tick + 1,
                type: SimEventType.busContested,
                nodeId: i,
              ));
            }
          } else {
            // Unpowered: retains soft ownership from last uncontested capture.
            clamped = 0;
            contested = 0;
            outSig = SignalState.lowNeutral;
          }

          internal[i] = (nextOwner & 0x3) | (clamped << 2) | (contested << 3);
          nextOut[i] = outSig;
      }
    }

    // Commit next-tick outputs and detect whether any wire output changed.
    bool anyOutputChanged = false;
    for (int i = 0; i < n; i++) {
      if (curOut[i] != nextOut[i]) {
        anyOutputChanged = true;
        curOut[i] = nextOut[i];
      }
    }

    state.tick++;
    state.phaseTicksRemaining--;

    if (state.phase == MatchPhase.liveCountdown) {
      if (state.phaseTicksRemaining <= 0) {
        if (topology.maxOvertimeTicks > 0) {
          state.phase = MatchPhase.overtime;
          state.phaseTicksRemaining = topology.maxOvertimeTicks;
          state.overtimeIdleStreak = 0;
        } else {
          state.phase = MatchPhase.finished;
          state.phaseTicksRemaining = 0;
        }
      }
    } else if (state.phase == MatchPhase.overtime) {
      if (!anyOutputChanged && !_hasActiveCausalTransient(topology, state)) {
        state.overtimeIdleStreak++;
      } else {
        state.overtimeIdleStreak = 0;
      }

      if (state.overtimeIdleStreak >= 2 || state.phaseTicksRemaining <= 0) {
        state.phase = MatchPhase.finished;
        state.phaseTicksRemaining = 0;
      }
    }
  }

  /// Fast-forwards [state] up to [maxTicks] or until [MatchPhase.finished].
  static void runUntilSettled(
    ArenaTopology topology,
    ArenaState state, {
    int maxTicks = 500,
  }) {
    for (int k = 0; k < maxTicks && state.phase != MatchPhase.finished; k++) {
      step(topology, state);
    }
  }

  static int _mergeStandardInputs(
    int nodeId,
    Uint16List inStart,
    Uint8List inSrc,
    Uint8List curOut,
  ) {
    int cyan = 0;
    int amber = 0;
    int contested = 0;
    for (int e = inStart[nodeId]; e < inStart[nodeId + 1]; e++) {
      final int sig = curOut[inSrc[e]];
      if (sig == SignalState.highCyan) {
        cyan++;
      } else if (sig == SignalState.highAmber) {
        amber++;
      } else if (sig == SignalState.contested) {
        contested++;
      }
    }
    if ((cyan > 0 && amber > 0) || contested > 0) {
      return SignalState.contested;
    }
    if (cyan > 0) return SignalState.highCyan;
    if (amber > 0) return SignalState.highAmber;
    return SignalState.lowNeutral;
  }

  static int _computeDynamicBias(ArenaTopology topology, ArenaState state) {
    final ({int cyan, int amber, int neutral}) score =
        state.computeBusScore(topology);
    if (score.cyan > score.amber) return SignalState.highCyan;
    if (score.amber > score.cyan) return SignalState.highAmber;
    return SignalState.lowNeutral;
  }

  static bool _hasActiveCausalTransient(
    ArenaTopology topology,
    ArenaState state,
  ) {
    final int n = topology.nodeCount;
    for (int i = 0; i < n; i++) {
      if (!topology.canReachBus(i)) continue;
      final NodeType t = topology.typeOf(i);
      switch (t) {
        case NodeType.inputRail:
        case NodeType.burstRail:
          if (state.railRemainingBurnTicks(i) > 0) return true;
        case NodeType.capacitor:
          if (state.capacitorChargeTicks(i) > 0) return true;
        case NodeType.clockOscillator:
          if (state.isClockAwake(i)) return true;
        case NodeType.buffer:
          int delay = topology.nodeParam[i];
          if (delay < 1) delay = 1;
          if (delay > 16) delay = 16;
          final int reg = state.nodeInternal[i];
          final int outSig = state.nodeOut[i];
          for (int k = 0; k < delay; k++) {
            if (((reg >>> (k * 2)) & 0x3) != outSig) return true;
          }
        default:
          break;
      }
    }
    return false;
  }
}
