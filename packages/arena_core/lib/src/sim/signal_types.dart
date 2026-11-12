/// Core dual-color Boolean signal, component, and match types for Logic Transfer Arena.

/// Wire and node output signal state combining Boolean level (0/1) with color ownership.
abstract final class SignalState {
  /// Logic 0, unpowered neutral wire.
  static const int lowNeutral = 0x00;

  /// Logic 1, driven by Cyan (Left / Bottom player).
  static const int highCyan = 0x01;

  /// Logic 1, driven by Amber (Right / Top player).
  static const int highAmber = 0x02;

  /// Contested interference state (sparks visually; evaluates as 0 downstream).
  static const int contested = 0x03;

  static bool isHigh(int signal) =>
      signal == highCyan || signal == highAmber;

  static ArenaSide? ownerOf(int signal) => switch (signal) {
        highCyan => ArenaSide.cyan,
        highAmber => ArenaSide.amber,
        _ => null,
      };

  static int fromSide(ArenaSide side) =>
      side == ArenaSide.cyan ? highCyan : highAmber;

  static String label(int signal) => switch (signal) {
        lowNeutral => 'LOW',
        highCyan => 'CYAN(1)',
        highAmber => 'AMBER(1)',
        contested => 'CONTESTED',
        _ => 'UNKNOWN($signal)',
      };
}

/// Competitor side on the arena circuit board.
enum ArenaSide {
  cyan(1),
  amber(2);

  const ArenaSide(this.code);
  final int code;

  ArenaSide get opponent => this == cyan ? amber : cyan;

  int get signal =>
      this == cyan ? SignalState.highCyan : SignalState.highAmber;

  static ArenaSide? fromCode(int code) => switch (code) {
        1 => ArenaSide.cyan,
        2 => ArenaSide.amber,
        _ => null,
      };
}

/// All circuit board node types (12 logic/hazard types + 2 rail types + Central Bus).
///
/// Total enum count is 15 (`0..14`), fitting inside 4 bits for compact URL hashes.
enum NodeType {
  /// Standard outer terminal; emits HIGH for [ArenaTopology.pulserBurnTicks] (4.0s).
  inputRail,

  /// Momentary burst launcher terminal; emits HIGH for [ArenaTopology.burstBurnTicks] (0.5s).
  burstRail,

  /// Passes input signal forward after N simulation ticks (default: 4 ticks).
  buffer,

  /// Duplicates an incoming active signal across 2 or 3 output branches (1-tick repeater).
  splitter,

  /// Inverter: outputs active signal of territory/VCC bias when input is 0; cuts off on 1.
  notGate,

  /// Outputs 1 only when all inputs are 1; color belongs to majority or final completer.
  andGate,

  /// Outputs 1 if any input is 1; enters Contested state if Cyan and Amber feed simultaneously.
  orGate,

  /// Outputs 1 when exactly one input is 1; simultaneous inputs cancel to 0.
  xorGate,

  /// Set pin locks output HIGH in triggering player's color; Reset pin clears to Neutral.
  srLatch,

  /// Triggered by a brief pulse; holds output HIGH for 3.0s (60 ticks) before decaying.
  capacitor,

  /// Dormant until hit; strobes 1/0 every 0.5s (10 ticks) in the last triggering player's color.
  clockOscillator,

  /// Absorbs signals with zero downstream effect.
  deadEnd,

  /// Central Bus scoring terminal (1x standard or 2x Core Node).
  busNode,

  /// Universal NAND gate: outputs territory VCC HIGH until all inputs are HIGH, then cuts to 0.
  nandGate,

  /// Universal NOR gate: outputs territory VCC HIGH only when all inputs are 0; any 1 cuts to 0.
  norGate;

  bool get isRail => this == inputRail || this == burstRail;

  /// Whether this gate socket can be reconfigured to another real Boolean gate during Pre-Round Prep.
  bool get isConfigurableSocket =>
      this == andGate ||
      this == orGate ||
      this == xorGate ||
      this == nandGate ||
      this == norGate ||
      this == notGate ||
      this == buffer ||
      this == splitter;

  /// Real logic gate types selectable in the Pre-Round Gate Configuration palette.
  static const List<NodeType> configurablePalette = <NodeType>[
    andGate,
    orGate,
    xorGate,
    nandGate,
    norGate,
    notGate,
    buffer,
  ];

  bool get isSwappableInPrep => isConfigurableSocket;

  bool get isInvertingGate =>
      this == notGate || this == nandGate || this == norGate;

  String get shortLabel => switch (this) {
        inputRail => 'RAIL',
        burstRail => 'BURST',
        buffer => 'BUF',
        splitter => 'SPL',
        notGate => 'NOT',
        andGate => 'AND',
        orGate => 'OR',
        xorGate => 'XOR',
        nandGate => 'NAND',
        norGate => 'NOR',
        srLatch => 'S·R',
        capacitor => 'CAP',
        clockOscillator => 'CLK',
        deadEnd => 'TERM',
        busNode => 'BUS',
      };
}

/// Pin semantics on incoming directed wire edges.
abstract final class PinRole {
  static const int standard = 0;
  static const int set = 1;
  static const int reset = 2;
}

/// Visual & scoring status of a Central Bus Node.
enum BusNodeStatus {
  neutral,
  softCyan,
  softAmber,
  clampedCyan,
  clampedAmber,
  contested;

  ArenaSide? get scoringOwner => switch (this) {
        softCyan || clampedCyan => ArenaSide.cyan,
        softAmber || clampedAmber => ArenaSide.amber,
        neutral || contested => null,
      };

  bool get isClamped => this == clampedCyan || this == clampedAmber;
}

/// Match lifecycle phase across Pre-Round Gate Prep + Live Transfer + Overtime.
enum MatchPhase {
  coinFlip,
  prepPhase,
  liveCountdown,
  overtime,
  finished,
}

/// Procedural or competitive board generation archetype.
enum BoardArchetype {
  mirrorSymmetric,
  pointSymmetric,
  latchHeavy,
  prepHybrid,
  underdogAsymmetric,
}

/// Discrete simulation events emitted for procedural audio and particle FX.
enum SimEventType {
  pulserDeployed,
  pulserBurnedOut,
  orContested,
  xorCancelled,
  andHijacked,
  latchLocked,
  latchReset,
  busCaptured,
  busContested,
  clockAwakened,
  deadEndFizzle,
}

/// Immutable simulation event emitted on state transitions when an event sink is attached.
final class SimEvent {
  final int tick;
  final SimEventType type;
  final int nodeId;
  final ArenaSide? side;

  const SimEvent({
    required this.tick,
    required this.type,
    required this.nodeId,
    this.side,
  });
}
