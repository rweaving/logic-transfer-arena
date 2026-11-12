# Happy Logic Simulator: Logic Transfer Arena

Competitive 1v1 dual-color Boolean gate combat game mode inspired by *Paradroid*'s Transfer hacking duel, built with **Dart 3**, **Flutter (`CustomPainter` + Impeller/WebGL `FragmentShader`)**, and **Cloudflare Workers + Durable Objects** deterministic lockstep rooms.

## Key Features

- **10.0s Pre-Round Logic Gate Configuration Countdown:** Before every live round, configure real Boolean logic gates (`AND`, `OR`, `XOR`, `NAND`, `NOR`, `NOT`, `BUF` 4-tick delay) and Jumper Wires (`+WIRE`) rendered with authentic IEEE/ANSI schematic symbols and CMOS `VCC` rail-power gating.
- **Interactive Sandbox Circuit Editor (`Sandbox -> Arena Bridge`):** Place, drag, mirror, and wire all 15 board components (`SET`/`RESET` SR-Latch pins, Burst Rails, Capacitors, Clock Oscillators, 2x Core Bus nodes) with live cycle-delay & causality checks and serverless `#arena=v1.<base64url>` (`CRC-16-CCITT`) circuit sharing.
- **Live 1v1 Online Lockstep PvP Rooms:** 4-character invite codes (`/api/rooms` & `/ws/room/:code`), synchronized Pre-Round Gate Prep & Ready lock-in (`0x05..0x08`), 4-byte binary `CMD_DEPLOY` / `EVT_INPUT` frames (`0x01..0x02`), 32-tick snapshot rollback `LockstepSession`, `FNV-1a` desync verification (`0x03..0x04`), Best-of-5 loser-picks-archetype drafts, and an optional real-WebSocket Bot Challenger for solo testing.
- **001–999 Droid AI Ladder & Daily Underdog Puzzles:** Pre-match `BoardTacticalProfile` static analyzer + horizon `RolloutEvaluator` (`~148 µs` per 340-tick rollout) + beam-search verified `3 vs 6` Daily Underdog puzzles.

## Workspace Layout

- `packages/arena_core` — Zero-Flutter pure Dart 3 simulation engine, procedural generator, fairness validator, `001–999` AI, `SandboxCircuitDraft`, and `CircuitUrlCodec`.
- `packages/arena_protocol` — Binary lockstep & Pre-Round prep packet codec + rollback-capable `LockstepSession`.
- `apps/logic_transfer_arena` — Responsive Flutter client (Web Wasm/JS, iOS, Android) with `shaders/pulse_wire.frag`, 90°-transposed mobile portrait layout, and procedural WebAudio/PCM synthesis.
- `services/arena_edge_rooms` — Cloudflare Worker + `ArenaMatchRoom` Durable Object for production edge deployment (`wrangler deploy`), mirrored locally by `serve_arena.mjs`.

## Quick Start

```bash
# Resolve Dart 3 workspace dependencies
flutter pub get

# Run simulation, determinism, Sandbox editor, URL codec, lockstep, and widget tests
dart test packages/arena_core packages/arena_protocol
flutter test apps/logic_transfer_arena

# Build WebAssembly bundle & serve with live WebSocket 1v1 rooms on port 8080
cd apps/logic_transfer_arena && flutter build web --wasm && cd ../..
node serve_arena.mjs
```
