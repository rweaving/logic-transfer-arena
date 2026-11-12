import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:arena_core/arena_core.dart';
import 'package:flutter/widgets.dart';

import 'spark_particle_pool.dart';

/// Palette constants strictly adhering to Cyan vs Amber hardware oscilloscope aesthetics.
abstract final class ArenaPalette {
  static const Color bgDeep = Color(0xFF090D14);
  static const Color panelBg = Color(0xFF101722);
  static const Color panelBorder = Color(0xFF1F2D40);
  static const Color copperUnlit = Color(0xFF223044);
  static const Color copperPinReset = Color(0xFF475569);

  static const Color cyanCore = Color(0xFF00E5FF);
  static const Color cyanGlow = Color(0x6600E5FF);
  static const Color cyanSoft = Color(0xFF0891B2);

  static const Color amberCore = Color(0xFFFFB000);
  static const Color amberGlow = Color(0x66FFB000);
  static const Color amberSoft = Color(0xFFD97706);

  static const Color contestedCore = Color(0xFFFFFBEB);
  static const Color contestedGlow = Color(0x88FDE68A);
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textMuted = Color(0xFF94A3B8);
}

/// Converts normalized Landscape board `(bx, by)` to screen `Offset`, applying
/// the 90-degree mobile Portrait transpose `(px, py) = (by, 1.0 - bx)` when [isPortrait] is true.
Offset boardToScreen(
  double bx,
  double by,
  Size size, {
  required bool isPortrait,
}) {
  if (isPortrait) {
    return Offset(by * size.width, (1.0 - bx) * size.height);
  }
  return Offset(bx * size.width, by * size.height);
}

/// Inverse transform from screen pointer `localPos` back to normalized board `(bx, by)`.
(double bx, double by) screenToBoard(
  Offset localPos,
  Size size, {
  required bool isPortrait,
}) {
  final double nx = (localPos.dx / math.max(1.0, size.width)).clamp(0.0, 1.0);
  final double ny = (localPos.dy / math.max(1.0, size.height)).clamp(0.0, 1.0);
  if (isPortrait) {
    return (1.0 - ny, nx);
  }
  return (nx, ny);
}

/// High-frequency `CustomPainter` rendering IEEE/ANSI logic gate schematics,
/// Pre-Round configurable gate sockets on both sides, sub-tick traveling pulses,
/// Central Bus clamp states, and AI Droid Probe reticle.
final class ArenaBoardPainter extends CustomPainter {
  final ArenaTopology topology;
  final ArenaState state;
  final double subTickAlpha;
  final double elapsedSec;
  final bool isPortrait;
  final ui.FragmentProgram? substrateProgram;
  final SparkParticlePool particles;

  /// Press-and-hold downstream trace highlight sets.
  final Set<int> highlightedNodes;
  final Set<int> highlightedWires;

  /// Selected source node during Pre-Round Jumper placement (`null` if none).
  final int? prepSelectedNode;

  /// Optional visible AI opponent rail/gate probe normalized coordinate (`[0..1]`).
  final double? amberProbePos;
  final bool amberProbeHovering;

  /// Optional debug wire/node inspector toggle.
  final bool showDebugTelemetry;

  ArenaBoardPainter({
    required this.topology,
    required this.state,
    required this.subTickAlpha,
    required this.elapsedSec,
    required this.isPortrait,
    required this.substrateProgram,
    required this.particles,
    required this.highlightedNodes,
    required this.highlightedWires,
    required this.prepSelectedNode,
    required this.amberProbePos,
    required this.amberProbeHovering,
    required this.showDebugTelemetry,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintSubstrate(canvas, size);
    _paintTerritoryZones(canvas, size);
    _paintWires(canvas, size);
    _paintNodes(canvas, size);
    if (amberProbePos != null &&
        (state.phase == MatchPhase.liveCountdown ||
            state.phase == MatchPhase.prepPhase)) {
      _paintAiProbe(canvas, size, amberProbePos!, amberProbeHovering);
    }
    particles.paint(canvas, size, isPortrait: isPortrait);
  }

  void _paintSubstrate(Canvas canvas, Size size) {
    final Rect full = Offset.zero & size;
    if (substrateProgram != null) {
      final ui.FragmentShader shader = substrateProgram!.fragmentShader();
      final double tension = (state.phase == MatchPhase.overtime ||
              (state.phase == MatchPhase.liveCountdown &&
                  state.phaseTicksRemaining <= 100))
          ? 1.0
          : 0.0;
      shader.setFloat(0, size.width);
      shader.setFloat(1, size.height);
      shader.setFloat(2, elapsedSec);
      shader.setFloat(3, tension);
      shader.setFloat(4, isPortrait ? 1.0 : 0.0);
      canvas.drawRect(full, Paint()..shader = shader);
      return;
    }

    final Paint bg = Paint()
      ..shader = ui.Gradient.linear(
        isPortrait ? Offset(0, size.height) : Offset.zero,
        isPortrait ? Offset.zero : Offset(size.width, 0),
        const <Color>[
          Color(0xFF0A141E),
          Color(0xFF090D14),
          Color(0xFF1A130A),
        ],
        const <double>[0.0, 0.5, 1.0],
      );
    canvas.drawRect(full, bg);
  }

  void _paintTerritoryZones(Canvas canvas, Size size) {
    final Offset busStart =
        boardToScreen(0.50, 0.05, size, isPortrait: isPortrait);
    final Offset busEnd =
        boardToScreen(0.50, 0.95, size, isPortrait: isPortrait);
    canvas.drawLine(
      busStart,
      busEnd,
      Paint()
        ..color = const Color(0xFF1E2E42)
        ..strokeWidth = 3.0,
    );

    // Highlight BOTH Cyan & Amber configurable gate bays during Pre-Round Prep Countdown!
    if (state.phase == MatchPhase.prepPhase) {
      final Rect cyanZone = isPortrait
          ? Rect.fromLTRB(
              8,
              size.height * 0.54,
              size.width - 8,
              size.height * 0.91,
            )
          : Rect.fromLTRB(
              size.width * 0.09,
              8,
              size.width * 0.46,
              size.height - 8,
            );
      final Rect amberZone = isPortrait
          ? Rect.fromLTRB(
              8,
              size.height * 0.09,
              size.width - 8,
              size.height * 0.46,
            )
          : Rect.fromLTRB(
              size.width * 0.54,
              8,
              size.width * 0.91,
              size.height - 8,
            );

      final RRect cRR = RRect.fromRectAndRadius(cyanZone, const Radius.circular(8));
      final RRect aRR = RRect.fromRectAndRadius(amberZone, const Radius.circular(8));

      canvas.drawRRect(
        cRR,
        Paint()..color = const Color(0x1200E5FF),
      );
      canvas.drawRRect(
        cRR,
        Paint()
          ..color = const Color(0x4800E5FF)
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke,
      );

      canvas.drawRRect(
        aRR,
        Paint()..color = const Color(0x12FFB000),
      );
      canvas.drawRRect(
        aRR,
        Paint()
          ..color = const Color(0x48FFB000)
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke,
      );

      _drawCenteredLabel(
        canvas,
        Offset(cyanZone.center.dx, cyanZone.top + 11),
        'CYAN LOGIC BAY (TAP GATES TO CONFIGURE)',
        fontSize: 9.5,
        color: const Color(0xAA00E5FF),
        bold: true,
      );
      _drawCenteredLabel(
        canvas,
        Offset(amberZone.center.dx, amberZone.top + 11),
        'AMBER LOGIC BAY (TAP GATES TO CONFIGURE)',
        fontSize: 9.5,
        color: const Color(0xAAFFB000),
        bold: true,
      );
    }
  }

  void _paintWires(Canvas canvas, Size size) {
    final Paint unlitPaint = Paint()
      ..color = ArenaPalette.copperUnlit
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final Paint resetUnlitPaint = Paint()
      ..color = ArenaPalette.copperPinReset
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final Paint highlightAura = Paint()
      ..color = const Color(0xAA38BDF8)
      ..strokeWidth = 5.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0)
      ..style = PaintingStyle.stroke;

    for (final WirePath w in topology.wires) {
      final Path path = _buildScreenPath(w, size);
      final int sig = state.nodeOut[w.srcNode];
      final bool isHighlighted = highlightedWires.contains(w.edgeIndex);

      if (isHighlighted) {
        canvas.drawPath(path, highlightAura);
      }

      if (sig == SignalState.lowNeutral) {
        canvas.drawPath(
          path,
          w.pinRole == PinRole.reset ? resetUnlitPaint : unlitPaint,
        );
        continue;
      }

      final Color coreColor = switch (sig) {
        SignalState.highCyan => ArenaPalette.cyanCore,
        SignalState.highAmber => ArenaPalette.amberCore,
        SignalState.contested => ArenaPalette.contestedCore,
        _ => ArenaPalette.copperUnlit,
      };
      final Color glowColor = switch (sig) {
        SignalState.highCyan => ArenaPalette.cyanGlow,
        SignalState.highAmber => ArenaPalette.amberGlow,
        SignalState.contested => ArenaPalette.contestedGlow,
        _ => const Color(0x00000000),
      };

      canvas.drawPath(
        path,
        Paint()
          ..color = glowColor
          ..strokeWidth = 6.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5)
          ..style = PaintingStyle.stroke,
      );

      canvas.drawPath(
        path,
        Paint()
          ..color = coreColor
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );

      final double basePhase =
          ((state.tick + subTickAlpha) * 0.22 + w.edgeIndex * 0.19) % 1.0;
      for (int k = 0; k < 2; k++) {
        final double u = (basePhase + k * 0.5) % 1.0;
        final (double bx, double by) = w.sampleAt(u);
        final Offset pt = boardToScreen(bx, by, size, isPortrait: isPortrait);
        canvas.drawCircle(
          pt,
          4.2,
          Paint()
            ..color = coreColor.withValues(alpha: 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
        );
        canvas.drawCircle(
          pt,
          2.1,
          Paint()..color = const Color(0xFFFFFFFF),
        );
      }
    }
  }

  void _paintNodes(Canvas canvas, Size size) {
    final double baseRadius =
        (math.min(size.width, size.height) * 0.032).clamp(14.0, 23.0);

    for (int i = 0; i < topology.nodeCount; i++) {
      final NodeType type = topology.typeOf(i);
      final Offset center = boardToScreen(
        topology.nodeX[i],
        topology.nodeY[i],
        size,
        isPortrait: isPortrait,
      );
      final int outSig = state.nodeOut[i];
      final bool isHighlighted =
          highlightedNodes.contains(i) || prepSelectedNode == i;

      if (isHighlighted) {
        canvas.drawCircle(
          center,
          baseRadius * 1.48,
          Paint()
            ..color = const Color(0x5538BDF8)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0),
        );
      }

      switch (type) {
        case NodeType.inputRail:
        case NodeType.burstRail:
          _paintRailNode(canvas, center, baseRadius, i, type);
        case NodeType.busNode:
          _paintBusNode(canvas, center, baseRadius * 1.15, i);
        default:
          _paintLogicGateNode(canvas, center, baseRadius, i, type, outSig);
      }
    }
  }

  void _paintRailNode(
    Canvas canvas,
    Offset center,
    double radius,
    int nodeId,
    NodeType type,
  ) {
    final bool isCyan = topology.nodeParam[nodeId] == ArenaSide.cyan.code;
    final ArenaSide side = isCyan ? ArenaSide.cyan : ArenaSide.amber;
    final Color accent =
        isCyan ? ArenaPalette.cyanCore : ArenaPalette.amberCore;
    final int remTicks = state.railRemainingBurnTicks(nodeId);
    final int coolTicks = state.railCooldownTicks(nodeId);
    final bool canFire = state.canDeployOnRail(topology, side, nodeId);

    final RRect pad = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: radius * 2.1,
        height: radius * 2.1,
      ),
      Radius.circular(radius * 0.45),
    );

    canvas.drawRRect(
      pad,
      Paint()
        ..color = remTicks > 0
            ? accent.withValues(alpha: 0.24)
            : ArenaPalette.panelBg,
    );

    canvas.drawRRect(
      pad,
      Paint()
        ..color = remTicks > 0
            ? accent
            : (canFire
                ? accent.withValues(alpha: 0.72)
                : ArenaPalette.copperPinReset)
        ..strokeWidth = remTicks > 0 ? 2.4 : 1.5
        ..style = PaintingStyle.stroke,
    );

    if (remTicks > 0) {
      final int maxBurn = type == NodeType.burstRail
          ? topology.burstBurnTicks
          : topology.pulserBurnTicks;
      final double frac =
          ((remTicks - subTickAlpha) / math.max(1, maxBurn)).clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.72),
        -math.pi / 2,
        math.pi * 2 * frac,
        false,
        Paint()
          ..color = accent
          ..strokeWidth = 3.0
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(
        center,
        radius * 0.30,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    } else if (coolTicks > 0) {
      canvas.drawCircle(
        center,
        radius * 0.25,
        Paint()..color = ArenaPalette.textMuted,
      );
    } else if (type == NodeType.burstRail) {
      _drawCenteredLabel(
        canvas,
        center,
        '⚡',
        fontSize: radius * 0.80,
        color: accent,
      );
    } else {
      canvas.drawCircle(
        center,
        radius * 0.30,
        Paint()
          ..color = canFire || state.phase == MatchPhase.prepPhase
              ? accent.withValues(alpha: 0.88)
              : ArenaPalette.copperUnlit,
      );
    }
  }

  void _paintBusNode(
    Canvas canvas,
    Offset center,
    double radius,
    int nodeId,
  ) {
    final BusNodeStatus status = state.busNodeStatus(nodeId);
    final bool isCore2x = topology.nodeParam[nodeId] >= 2;
    final double r = isCore2x ? radius * 1.16 : radius * 0.96;

    final Color fill = switch (status) {
      BusNodeStatus.clampedCyan => const Color(0xFF064E63),
      BusNodeStatus.softCyan => const Color(0xFF0A2E3D),
      BusNodeStatus.clampedAmber => const Color(0xFF633B06),
      BusNodeStatus.softAmber => const Color(0xFF3B2508),
      BusNodeStatus.contested => const Color(0xFF47412A),
      BusNodeStatus.neutral => ArenaPalette.panelBg,
    };

    final Color rim = switch (status) {
      BusNodeStatus.clampedCyan => ArenaPalette.cyanCore,
      BusNodeStatus.softCyan => ArenaPalette.cyanSoft,
      BusNodeStatus.clampedAmber => ArenaPalette.amberCore,
      BusNodeStatus.softAmber => ArenaPalette.amberSoft,
      BusNodeStatus.contested => ArenaPalette.contestedCore,
      BusNodeStatus.neutral => const Color(0xFF334155),
    };

    if (status.isClamped || status == BusNodeStatus.contested) {
      canvas.drawCircle(
        center,
        r * 1.28,
        Paint()
          ..color = rim.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0),
      );
    }

    final Path oct = _octagonPath(center, r);
    canvas.drawPath(oct, Paint()..color = fill);
    canvas.drawPath(
      oct,
      Paint()
        ..color = rim
        ..strokeWidth = status.isClamped ? 2.6 : 1.6
        ..style = PaintingStyle.stroke,
    );

    if (isCore2x) {
      canvas.drawCircle(
        center,
        r * 0.62,
        Paint()
          ..color = rim.withValues(alpha: 0.75)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      _drawCenteredLabel(
        canvas,
        center,
        '2×',
        fontSize: r * 0.58,
        color: ArenaPalette.textPrimary,
        bold: true,
      );
    } else if (status.isClamped) {
      canvas.drawCircle(
        center,
        r * 0.28,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    } else if (status.scoringOwner != null) {
      canvas.drawCircle(
        center,
        r * 0.28,
        Paint()
          ..color = rim
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// Renders authentic IEEE/ANSI Boolean gate schematics + Pre-Round socket rings.
  void _paintLogicGateNode(
    Canvas canvas,
    Offset center,
    double radius,
    int nodeId,
    NodeType type,
    int outSig,
  ) {
    final ArenaSide? socketSide = topology.configurableSideOf(nodeId);
    final bool inPrep =
        state.phase == MatchPhase.prepPhase && socketSide != null;

    // Socket highlight ring during Pre-Round Gate Configuration Countdown!
    if (inPrep) {
      final double pulse = 0.60 + 0.40 * math.sin(elapsedSec * 5.2);
      final Color bayCol = socketSide == ArenaSide.cyan
          ? ArenaPalette.cyanCore
          : ArenaPalette.amberCore;
      final RRect socketBox = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: radius * 2.55,
          height: radius * 2.05,
        ),
        Radius.circular(radius * 0.42),
      );
      canvas.drawRRect(
        socketBox,
        Paint()
          ..color = bayCol.withValues(alpha: 0.14 + 0.14 * pulse)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        socketBox,
        Paint()
          ..color = bayCol.withValues(alpha: 0.55 + 0.35 * pulse)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }

    final Color activeColor = switch (outSig) {
      SignalState.highCyan => ArenaPalette.cyanCore,
      SignalState.highAmber => ArenaPalette.amberCore,
      SignalState.contested => ArenaPalette.contestedCore,
      _ => socketSide == ArenaSide.cyan
          ? const Color(0xFF3B667D)
          : (socketSide == ArenaSide.amber
              ? const Color(0xFF7D5D33)
              : const Color(0xFF475569)),
    };

    final Color fillColor = SignalState.isHigh(outSig)
        ? activeColor.withValues(alpha: 0.22)
        : const Color(0xFF111926);

    // Direction gate points (toward Central Bus at x=0.50):
    final bool leftHalf = topology.nodeX[nodeId] <= 0.50;
    final double headingRad = isPortrait
        ? (leftHalf ? -math.pi / 2.0 : math.pi / 2.0)
        : (leftHalf ? 0.0 : math.pi);

    final bool hasIeeeShape = type == NodeType.andGate ||
        type == NodeType.nandGate ||
        type == NodeType.orGate ||
        type == NodeType.norGate ||
        type == NodeType.xorGate ||
        type == NodeType.notGate ||
        type == NodeType.buffer;

    if (hasIeeeShape) {
      _paintIeeeGateShape(
        canvas,
        center: center,
        r: radius * 0.96,
        headingRad: headingRad,
        type: type,
        fill: fillColor,
        stroke: activeColor,
        strokeWidth: outSig == SignalState.lowNeutral ? 1.6 : 2.3,
      );
    } else {
      final RRect body = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center,
          width: radius * 2.15,
          height: radius * 1.65,
        ),
        Radius.circular(radius * 0.36),
      );
      canvas.drawRRect(body, Paint()..color = fillColor);
      canvas.drawRRect(
        body,
        Paint()
          ..color = activeColor
          ..strokeWidth = outSig == SignalState.lowNeutral ? 1.4 : 2.2
          ..style = PaintingStyle.stroke,
      );
    }

    _drawCenteredLabel(
      canvas,
      hasIeeeShape ? center.translate(0, radius * 1.24) : center,
      type.shortLabel,
      fontSize: hasIeeeShape ? radius * 0.48 : radius * 0.56,
      color: outSig == SignalState.lowNeutral
          ? ArenaPalette.textMuted
          : ArenaPalette.textPrimary,
      bold: true,
    );

    // Component-specific live micro-telemetry!
    if (type == NodeType.buffer) {
      final int delay = topology.nodeParam[nodeId].clamp(1, 8);
      final int reg = state.nodeInternal[nodeId];
      final double dotSpan = radius * 1.1;
      for (int k = 0; k < delay; k++) {
        final int slotSig = (reg >>> ((delay - 1 - k) * 2)) & 0x3;
        final double dx = delay == 1
            ? 0.0
            : -dotSpan * 0.5 + (dotSpan * k) / (delay - 1);
        final Color dotCol = switch (slotSig) {
          SignalState.highCyan => ArenaPalette.cyanCore,
          SignalState.highAmber => ArenaPalette.amberCore,
          SignalState.contested => ArenaPalette.contestedCore,
          _ => const Color(0xFF263548),
        };
        canvas.drawCircle(
          center.translate(dx, 0),
          1.9,
          Paint()..color = dotCol,
        );
      }
    } else if (type == NodeType.capacitor) {
      final int charge = state.capacitorChargeTicks(nodeId);
      if (charge > 0) {
        final double frac = (charge / 60.0).clamp(0.0, 1.0);
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius * 1.12),
          -math.pi / 2,
          math.pi * 2 * frac,
          false,
          Paint()
            ..color = activeColor
            ..strokeWidth = 2.2
            ..style = PaintingStyle.stroke,
        );
      }
    } else if (type == NodeType.srLatch) {
      final ArenaSide? locked = state.latchStoredOwner(nodeId);
      if (locked != null) {
        final Color lockCol = locked == ArenaSide.cyan
            ? ArenaPalette.cyanCore
            : ArenaPalette.amberCore;
        canvas.drawLine(
          center.translate(-radius * 0.85, -radius * 0.82),
          center.translate(radius * 0.85, -radius * 0.82),
          Paint()
            ..color = lockCol
            ..strokeWidth = 3.0
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    if (showDebugTelemetry) {
      _drawCenteredLabel(
        canvas,
        center.translate(0, -radius * 1.25),
        '#$nodeId',
        fontSize: 9.0,
        color: const Color(0xFF64748B),
      );
    }
  }

  /// Draws true IEEE/ANSI hardware schematic symbols in local gate coordinates (`+X` = output).
  void _paintIeeeGateShape(
    Canvas canvas, {
    required Offset center,
    required double r,
    required double headingRad,
    required NodeType type,
    required Color fill,
    required Color stroke,
    required double strokeWidth,
  }) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(headingRad);

    final Paint fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.fill;
    final Paint strokePaint = Paint()
      ..color = stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final double w = r * 1.05;
    final double h = r * 0.84;

    switch (type) {
      case NodeType.andGate:
      case NodeType.nandGate:
        final Path p = Path()
          ..moveTo(-w, -h)
          ..lineTo(0, -h)
          ..arcToPoint(
            Offset(0, h),
            radius: Radius.circular(h),
            clockwise: true,
          )
          ..lineTo(-w, h)
          ..close();
        canvas.drawPath(p, fillPaint);
        canvas.drawPath(p, strokePaint);
        if (type == NodeType.nandGate) {
          final Offset bubble = Offset(h + r * 0.22, 0);
          canvas.drawCircle(bubble, r * 0.20, fillPaint);
          canvas.drawCircle(bubble, r * 0.20, strokePaint);
        }

      case NodeType.orGate:
      case NodeType.norGate:
      case NodeType.xorGate:
        final double shiftX = type == NodeType.xorGate ? r * 0.14 : 0.0;
        final Path p = Path()
          ..moveTo(-w + shiftX, -h)
          ..quadraticBezierTo(w * 0.25, -h, w, 0)
          ..quadraticBezierTo(w * 0.25, h, -w + shiftX, h)
          ..quadraticBezierTo(-w * 0.42 + shiftX, 0, -w + shiftX, -h)
          ..close();
        canvas.drawPath(p, fillPaint);
        canvas.drawPath(p, strokePaint);

        if (type == NodeType.xorGate) {
          final Path xorArc = Path()
            ..moveTo(-w - r * 0.18, -h)
            ..quadraticBezierTo(-w * 0.60 - r * 0.18, 0, -w - r * 0.18, h);
          canvas.drawPath(xorArc, strokePaint);
        } else if (type == NodeType.norGate) {
          final Offset bubble = Offset(w + r * 0.22, 0);
          canvas.drawCircle(bubble, r * 0.20, fillPaint);
          canvas.drawCircle(bubble, r * 0.20, strokePaint);
        }

      case NodeType.notGate:
      case NodeType.buffer:
        final Path tri = Path()
          ..moveTo(-w * 0.90, -h * 0.92)
          ..lineTo(w * 0.85, 0)
          ..lineTo(-w * 0.90, h * 0.92)
          ..close();
        canvas.drawPath(tri, fillPaint);
        canvas.drawPath(tri, strokePaint);
        if (type == NodeType.notGate) {
          final Offset bubble = Offset(w * 0.85 + r * 0.22, 0);
          canvas.drawCircle(bubble, r * 0.20, fillPaint);
          canvas.drawCircle(bubble, r * 0.20, strokePaint);
        }

      default:
        break;
    }

    canvas.restore();
  }

  void _paintAiProbe(
    Canvas canvas,
    Size size,
    double normY,
    bool hovering,
  ) {
    final double probeX =
        state.phase == MatchPhase.prepPhase ? 0.72 : 0.94;
    final Offset pos =
        boardToScreen(probeX, normY, size, isPortrait: isPortrait);
    final double pulse = 1.0 + 0.14 * math.sin(elapsedSec * 9.0);
    final double r = (hovering ? 20.0 : 16.0) * pulse;

    canvas.drawCircle(
      pos,
      r,
      Paint()
        ..color =
            hovering ? const Color(0xAAFFB000) : const Color(0x66FFB000)
        ..strokeWidth = hovering ? 2.4 : 1.5
        ..style = PaintingStyle.stroke,
    );

    final Paint tickPaint = Paint()
      ..color = ArenaPalette.amberCore
      ..strokeWidth = 2.0;
    canvas.drawLine(
      pos.translate(-r - 4, 0),
      pos.translate(-r + 3, 0),
      tickPaint,
    );
    canvas.drawLine(
      pos.translate(r - 3, 0),
      pos.translate(r + 4, 0),
      tickPaint,
    );
  }

  Path _buildScreenPath(WirePath w, Size size) {
    final Path path = Path();
    final Offset p0 = boardToScreen(
      w.points[0],
      w.points[1],
      size,
      isPortrait: isPortrait,
    );
    path.moveTo(p0.dx, p0.dy);
    for (int i = 2; i < w.points.length; i += 2) {
      final Offset p = boardToScreen(
        w.points[i],
        w.points[i + 1],
        size,
        isPortrait: isPortrait,
      );
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  Path _octagonPath(Offset center, double r) {
    final Path path = Path();
    for (int k = 0; k < 8; k++) {
      final double a = (math.pi / 8.0) + k * (math.pi / 4.0);
      final Offset pt = Offset(
        center.dx + math.cos(a) * r,
        center.dy + math.sin(a) * r,
      );
      if (k == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    return path;
  }

  void _drawCenteredLabel(
    Canvas canvas,
    Offset center,
    String text, {
    required double fontSize,
    required Color color,
    bool bold = false,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          fontFamily: 'monospace',
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center.translate(-tp.width * 0.5, -tp.height * 0.5));
  }

  @override
  bool shouldRepaint(covariant ArenaBoardPainter oldDelegate) => true;
}
