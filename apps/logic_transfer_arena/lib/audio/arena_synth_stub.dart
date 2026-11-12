import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Pure-Dart parametric 16-bit PCM synthesizer & haptic driver for Native/Test targets.
///
/// Pre-computes compact PCM waveforms (`< 96 KB`) in memory and triggers platform
/// tactile clicks when running outside browser WebAudio.
final Map<String, Uint8List> _pcmBank = <String, Uint8List>{};
bool _initialized = false;

void unlockAudio() {
  if (_initialized) return;
  _initialized = true;
  _pcmBank['click_cyan'] = _synthesizeTone(freqStart: 420, freqEnd: 140, ms: 28);
  _pcmBank['click_amber'] = _synthesizeTone(freqStart: 320, freqEnd: 110, ms: 28);
  _pcmBank['zap'] = _synthesizeTone(freqStart: 1180, freqEnd: 260, ms: 65);
}

void playRelayClick({required bool isCyan}) {
  unlockAudio();
  HapticFeedback.selectionClick();
}

void playBurnoutDecay() {}

void playBusCaptureChime({required int comboStep, required bool isCyan}) {
  if (isCyan && comboStep >= 3) {
    HapticFeedback.lightImpact();
  }
}

void playCollisionZap() {
  HapticFeedback.mediumImpact();
}

void playHijackSweep({required bool isCyan}) {
  HapticFeedback.lightImpact();
}

void playLatchVaultLock({required bool isCyan}) {
  HapticFeedback.mediumImpact();
}

void playLatchResetSnipe() {
  HapticFeedback.lightImpact();
}

void playClockPing() {}

void playDeadEndFizzle() {}

void playHeartbeat({required bool urgent}) {}

Uint8List _synthesizeTone({
  required double freqStart,
  required double freqEnd,
  required int ms,
}) {
  const int sampleRate = 22050;
  final int samples = (sampleRate * ms) ~/ 1000;
  final ByteData wav = ByteData(44 + samples * 2);
  double phase = 0.0;
  for (int i = 0; i < samples; i++) {
    final double t = i / samples;
    final double freq = freqStart + (freqEnd - freqStart) * t;
    final double env = (1.0 - t) * (1.0 - t);
    phase += (2.0 * math.pi * freq) / sampleRate;
    final int pcm = (math.sin(phase) * env * 14000).round().clamp(-32768, 32767);
    wav.setInt16(44 + i * 2, pcm, Endian.little);
  }
  return wav.buffer.asUint8List();
}
