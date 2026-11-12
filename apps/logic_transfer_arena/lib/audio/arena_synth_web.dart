import 'dart:js_interop';

@JS('AudioContext')
extension type _JsAudioContext._(JSObject _) implements JSObject {
  external factory _JsAudioContext();
  external double get currentTime;
  external String get state;
  external JSPromise<JSAny?> resume();
  external _JsAudioNode get destination;
  external _JsOscillatorNode createOscillator();
  external _JsGainNode createGain();
}

extension type _JsAudioNode._(JSObject _) implements JSObject {
  external void connect(_JsAudioNode destination);
}

extension type _JsAudioParam._(JSObject _) implements JSObject {
  external set value(double v);
  external void setValueAtTime(double value, double startTime);
  external void exponentialRampToValueAtTime(double value, double endTime);
  external void linearRampToValueAtTime(double value, double endTime);
}

extension type _JsOscillatorNode._(JSObject _) implements _JsAudioNode {
  external set type(String value);
  external _JsAudioParam get frequency;
  external void start([double when]);
  external void stop([double when]);
}

extension type _JsGainNode._(JSObject _) implements _JsAudioNode {
  external _JsAudioParam get gain;
}

_JsAudioContext? _ctx;

_JsAudioContext? _ensureCtx() {
  try {
    _ctx ??= _JsAudioContext();
    if (_ctx!.state == 'suspended') {
      _ctx!.resume();
    }
    return _ctx;
  } catch (_) {
    return null;
  }
}

void unlockAudio() {
  _ensureCtx();
}

void _tone({
  required String wave,
  required double f0,
  required double f1,
  required double durationSec,
  required double peakGain,
}) {
  final _JsAudioContext? ctx = _ensureCtx();
  if (ctx == null) return;
  try {
    final double now = ctx.currentTime;
    final _JsOscillatorNode osc = ctx.createOscillator();
    final _JsGainNode gain = ctx.createGain();
    osc.type = wave;
    osc.frequency.setValueAtTime(f0, now);
    osc.frequency.exponentialRampToValueAtTime(
      f1.clamp(20.0, 12000.0),
      now + durationSec,
    );
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.linearRampToValueAtTime(peakGain, now + 0.004);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + durationSec);

    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + durationSec + 0.01);
  } catch (_) {
    // Ignore audio context autoplay restrictions before gesture.
  }
}

void playRelayClick({required bool isCyan}) {
  _tone(
    wave: 'triangle',
    f0: isCyan ? 580.0 : 440.0,
    f1: isCyan ? 180.0 : 140.0,
    durationSec: 0.045,
    peakGain: 0.14,
  );
}

void playBurnoutDecay() {
  _tone(
    wave: 'sine',
    f0: 210.0,
    f1: 75.0,
    durationSec: 0.08,
    peakGain: 0.05,
  );
}

const List<double> _pentatonicHz = <double>[
  523.25, // C5
  587.33, // D5
  659.25, // E5
  783.99, // G5
  880.00, // A5
  1046.50, // C6
  1174.66, // D6
  1318.51, // E6
];

void playBusCaptureChime({required int comboStep, required bool isCyan}) {
  if (isCyan) {
    final double hz = _pentatonicHz[(comboStep - 1).clamp(0, _pentatonicHz.length - 1)];
    _tone(
      wave: 'sine',
      f0: hz,
      f1: hz * 1.02,
      durationSec: 0.14,
      peakGain: 0.12,
    );
  } else {
    _tone(
      wave: 'sawtooth',
      f0: 293.66,
      f1: 246.94,
      durationSec: 0.11,
      peakGain: 0.07,
    );
  }
}

void playCollisionZap() {
  _tone(
    wave: 'sawtooth',
    f0: 1320.0,
    f1: 190.0,
    durationSec: 0.09,
    peakGain: 0.11,
  );
}

void playHijackSweep({required bool isCyan}) {
  _tone(
    wave: 'triangle',
    f0: isCyan ? 360.0 : 520.0,
    f1: isCyan ? 920.0 : 280.0,
    durationSec: 0.13,
    peakGain: 0.12,
  );
}

void playLatchVaultLock({required bool isCyan}) {
  _tone(
    wave: 'square',
    f0: isCyan ? 392.0 : 311.13,
    f1: isCyan ? 784.0 : 466.16,
    durationSec: 0.16,
    peakGain: 0.09,
  );
}

void playLatchResetSnipe() {
  _tone(
    wave: 'sawtooth',
    f0: 880.0,
    f1: 220.0,
    durationSec: 0.12,
    peakGain: 0.10,
  );
}

void playClockPing() {
  _tone(
    wave: 'sine',
    f0: 987.77,
    f1: 987.77,
    durationSec: 0.06,
    peakGain: 0.08,
  );
}

void playDeadEndFizzle() {
  _tone(
    wave: 'triangle',
    f0: 150.0,
    f1: 52.0,
    durationSec: 0.12,
    peakGain: 0.09,
  );
}

void playHeartbeat({required bool urgent}) {
  _tone(
    wave: 'sine',
    f0: urgent ? 78.0 : 62.0,
    f1: 38.0,
    durationSec: 0.12,
    peakGain: urgent ? 0.16 : 0.11,
  );
}
