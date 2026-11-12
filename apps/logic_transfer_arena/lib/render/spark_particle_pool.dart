import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:arena_core/arena_core.dart';

/// Pre-allocated zero-allocation particle ring buffer for OR/XOR sparks and Bus captures.
final class SparkParticlePool {
  static const int capacity = 160;

  final Float32List _x = Float32List(capacity);
  final Float32List _y = Float32List(capacity);
  final Float32List _vx = Float32List(capacity);
  final Float32List _vy = Float32List(capacity);
  final Float32List _life = Float32List(capacity);
  final Float32List _maxLife = Float32List(capacity);
  final Uint32List _colorArgb = Uint32List(capacity);

  int _cursor = 0;
  int _seed = 0x5A17C9E3;

  void clear() {
    _life.fillRange(0, capacity, 0.0);
  }

  void spawnBurst({
    required double normX,
    required double normY,
    required int count,
    required int colorArgb,
    double speed = 0.22,
    double durationSec = 0.42,
  }) {
    for (int k = 0; k < count; k++) {
      final int idx = _cursor;
      _cursor = (_cursor + 1) % capacity;

      final double angle = _nextUnit() * math.pi * 2.0;
      final double mag = speed * (0.35 + 0.65 * _nextUnit());

      _x[idx] = normX;
      _y[idx] = normY;
      _vx[idx] = math.cos(angle) * mag;
      _vy[idx] = math.sin(angle) * mag;
      _life[idx] = durationSec;
      _maxLife[idx] = durationSec;
      _colorArgb[idx] = colorArgb;
    }
  }

  void spawnFromEvents(ArenaTopology topology, List<SimEvent> events) {
    for (final SimEvent ev in events) {
      if (ev.nodeId < 0 || ev.nodeId >= topology.nodeCount) continue;
      final double nx = topology.nodeX[ev.nodeId];
      final double ny = topology.nodeY[ev.nodeId];

      switch (ev.type) {
        case SimEventType.orContested:
        case SimEventType.xorCancelled:
        case SimEventType.busContested:
          spawnBurst(
            normX: nx,
            normY: ny,
            count: 14,
            colorArgb: 0xFFFFF3C4,
            speed: 0.28,
            durationSec: 0.38,
          );
        case SimEventType.busCaptured:
          spawnBurst(
            normX: nx,
            normY: ny,
            count: 12,
            colorArgb: ev.side == ArenaSide.cyan ? 0xFF00E5FF : 0xFFFFB000,
            speed: 0.20,
            durationSec: 0.46,
          );
        case SimEventType.latchLocked:
        case SimEventType.andHijacked:
          spawnBurst(
            normX: nx,
            normY: ny,
            count: 10,
            colorArgb: ev.side == ArenaSide.cyan ? 0xFF38BDF8 : 0xFFF59E0B,
            speed: 0.18,
            durationSec: 0.40,
          );
        case SimEventType.latchReset:
          spawnBurst(
            normX: nx,
            normY: ny,
            count: 10,
            colorArgb: 0xFFE2E8F0,
            speed: 0.22,
            durationSec: 0.34,
          );
        case SimEventType.deadEndFizzle:
          spawnBurst(
            normX: nx,
            normY: ny,
            count: 7,
            colorArgb: 0xFF94A3B8,
            speed: 0.11,
            durationSec: 0.30,
          );
        default:
          break;
      }
    }
  }

  void step(double dtSec) {
    final double drag = math.pow(0.08, dtSec).toDouble();
    for (int i = 0; i < capacity; i++) {
      final double l = _life[i];
      if (l <= 0.0) continue;
      final double nextL = l - dtSec;
      if (nextL <= 0.0) {
        _life[i] = 0.0;
        continue;
      }
      _life[i] = nextL;
      _x[i] += _vx[i] * dtSec;
      _y[i] += _vy[i] * dtSec;
      _vx[i] *= drag;
      _vy[i] *= drag;
    }
  }

  void paint(
    Canvas canvas,
    Size size, {
    required bool isPortrait,
  }) {
    final Paint paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < capacity; i++) {
      final double l = _life[i];
      if (l <= 0.0) continue;
      final double ratio = (l / _maxLife[i]).clamp(0.0, 1.0);
      final int argb = _colorArgb[i];
      final int alpha = (ratio * 255).round().clamp(0, 255);
      paint.color = Color((argb & 0x00FFFFFF) | (alpha << 24));

      final double px = isPortrait ? _y[i] * size.width : _x[i] * size.width;
      final double py =
          isPortrait ? (1.0 - _x[i]) * size.height : _y[i] * size.height;
      final double radius = 1.6 + 2.8 * ratio;
      canvas.drawCircle(Offset(px, py), radius, paint);
    }
  }

  double _nextUnit() {
    _seed = (_seed ^ (_seed << 13)) & 0xFFFFFFFF;
    _seed = (_seed ^ (_seed >>> 17)) & 0xFFFFFFFF;
    _seed = (_seed ^ (_seed << 5)) & 0xFFFFFFFF;
    return (_seed & 0xFFFFFF) / 16777216.0;
  }
}
