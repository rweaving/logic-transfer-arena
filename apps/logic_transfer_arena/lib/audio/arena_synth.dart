import 'package:arena_core/arena_core.dart';

import 'arena_synth_stub.dart'
    if (dart.library.js_interop) 'arena_synth_web.dart' as impl;

/// Cross-platform zero-asset procedural sound synthesizer for Logic Transfer Arena.
final class ArenaSynth {
  bool muted = false;
  int _cyanComboStreak = 0;

  void unlock() => impl.unlockAudio();

  void resetMatch() {
    _cyanComboStreak = 0;
  }

  void handleEvents(List<SimEvent> events) {
    if (muted) return;
    for (final SimEvent ev in events) {
      switch (ev.type) {
        case SimEventType.pulserDeployed:
          impl.playRelayClick(isCyan: ev.side == ArenaSide.cyan);
        case SimEventType.pulserBurnedOut:
          impl.playBurnoutDecay();
        case SimEventType.busCaptured:
          if (ev.side == ArenaSide.cyan) {
            _cyanComboStreak = (_cyanComboStreak + 1).clamp(1, 8);
            impl.playBusCaptureChime(comboStep: _cyanComboStreak, isCyan: true);
          } else {
            _cyanComboStreak = 0;
            impl.playBusCaptureChime(comboStep: 1, isCyan: false);
          }
        case SimEventType.orContested:
        case SimEventType.xorCancelled:
        case SimEventType.busContested:
          impl.playCollisionZap();
        case SimEventType.andHijacked:
          impl.playHijackSweep(isCyan: ev.side == ArenaSide.cyan);
        case SimEventType.latchLocked:
          impl.playLatchVaultLock(isCyan: ev.side == ArenaSide.cyan);
        case SimEventType.latchReset:
          impl.playLatchResetSnipe();
        case SimEventType.clockAwakened:
          impl.playClockPing();
        case SimEventType.deadEndFizzle:
          impl.playDeadEndFizzle();
      }
    }
  }

  void playCountdownHeartbeat({required bool urgent}) {
    if (muted) return;
    impl.playHeartbeat(urgent: urgent);
  }
}
