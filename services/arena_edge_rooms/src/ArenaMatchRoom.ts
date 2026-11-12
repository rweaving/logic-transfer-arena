/// Authoritative Input-Relay Lockstep, Pre-Round Gate Prep & Best-of-5 Duel Room Durable Object.
///
/// Binary opcodes match `packages/arena_protocol`:
/// - `0x01` CMD_DEPLOY:      [0x01, clientTickHi, clientTickLo, railIndex]
/// - `0x02` EVT_INPUT:       [0x02, execTickHi, execTickLo, (sideCode << 6) | railIndex]
/// - `0x03` HASH_CHECK:      [0x03, tickHi, tickLo, h3, h2, h1, h0]
/// - `0x04` DESYNC_ALERT:    [0x04, tickHi, tickLo]
/// - `0x05` CMD_PREP_GATE:   [0x05, nodeId, newNodeTypeIndex]
/// - `0x06` CMD_PREP_WIRE:   [0x06, srcNodeId, dstNodeId, pinRole]
/// - `0x07` EVT_PREP_APPLIED:[0x07, kind(0=gate,1=wire), sideCode, a, b | (pinRole << 6)]
/// - `0x08` CMD_PREP_READY:  [0x08, ready(0|1)]

type Side = "cyan" | "amber";
type Archetype = "mirrorSymmetric" | "pointSymmetric" | "latchHeavy" | "prepHybrid";

interface PlayerAttachment {
  side: Side;
  joinedAtMs: number;
}

const OPCODE_CMD_DEPLOY = 0x01;
const OPCODE_EVT_INPUT = 0x02;
const OPCODE_HASH_CHECK = 0x03;
const OPCODE_DESYNC_ALERT = 0x04;
const OPCODE_CMD_PREP_GATE = 0x05;
const OPCODE_CMD_PREP_WIRE = 0x06;
const OPCODE_EVT_PREP_APPLIED = 0x07;
const OPCODE_CMD_PREP_READY = 0x08;

const TICK_MS = 50; // 20Hz simulation
const INPUT_HORIZON_TICKS = 2;
const PREP_DURATION_MS = 10000; // 10.0s Pre-Round Gate Configuration Countdown

export class ArenaMatchRoom {
  private readonly ctx: DurableObjectState;
  private roundNumber = 1;
  private cyanWins = 0;
  private amberWins = 0;
  private loserSide: Side | null = null;
  private nextArchetype: Archetype = "mirrorSymmetric";
  private customUrlHash: string | null = null;
  private inPrepPhase = false;
  private cyanPrepReady = false;
  private amberPrepReady = false;
  private liveStartEpochMs = 0;
  private hashByTick = new Map<number, { side: Side; hash: number }>();

  constructor(ctx: DurableObjectState) {
    this.ctx = ctx;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    const existing = this.ctx.getWebSockets();
    if (existing.length >= 2) {
      return new Response("Room full (1v1 duel in progress)", { status: 409 });
    }

    const url = new URL(request.url);
    const initialBoard = url.searchParams.get("board");
    if (initialBoard && initialBoard.startsWith("#arena=v1.")) {
      this.customUrlHash = initialBoard;
    }

    const assignedSide: Side = this.isSideTaken("cyan") ? "amber" : "cyan";
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    const attachment: PlayerAttachment = {
      side: assignedSide,
      joinedAtMs: Date.now(),
    };
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(attachment);

    server.send(
      JSON.stringify({
        type: "WELCOME",
        side: assignedSide,
        playersConnected: existing.length + 1,
      })
    );

    this.broadcastJson({
      type: "ROOM_STATUS",
      playersConnected: existing.length + 1,
    });

    if (existing.length + 1 === 2) {
      this.startRound();
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(
    ws: WebSocket,
    message: string | ArrayBuffer
  ): Promise<void> {
    const attachment = ws.deserializeAttachment() as PlayerAttachment | null;
    if (!attachment) return;

    if (message instanceof ArrayBuffer) {
      const bytes = new Uint8Array(message);
      if (bytes.length === 0) return;

      switch (bytes[0]) {
        case OPCODE_CMD_DEPLOY:
          if (bytes.length >= 4) this.handleBinaryDeploy(attachment.side, bytes);
          break;
        case OPCODE_HASH_CHECK:
          if (bytes.length >= 7) this.handleHashCheck(attachment.side, bytes);
          break;
        case OPCODE_CMD_PREP_GATE:
          if (bytes.length >= 3 && this.inPrepPhase) {
            this.relayPrepEdit(attachment.side, 0, bytes[1] & 0x3f, bytes[2] & 0x3f, 0);
          }
          break;
        case OPCODE_CMD_PREP_WIRE:
          if (bytes.length >= 4 && this.inPrepPhase) {
            this.relayPrepEdit(
              attachment.side,
              1,
              bytes[1] & 0x3f,
              bytes[2] & 0x3f,
              bytes[3] & 0x03
            );
          }
          break;
        case OPCODE_CMD_PREP_READY:
          if (bytes.length >= 2 && this.inPrepPhase) {
            this.handlePrepReady(attachment.side, bytes[1] !== 0);
          }
          break;
      }
      return;
    }

    const msg = JSON.parse(message) as Record<string, unknown>;
    if (msg.type === "SET_CUSTOM_BOARD" && typeof msg.urlHash === "string") {
      if (msg.urlHash.startsWith("#arena=v1.")) {
        this.customUrlHash = msg.urlHash;
        if (this.ctx.getWebSockets().length === 2) {
          this.startRound();
        }
      }
    } else if (msg.type === "ROUND_RESULT") {
      const cyanPts = Number(msg.cyanPoints ?? 0);
      const amberPts = Number(msg.amberPoints ?? 0);
      this.recordRoundOutcome(cyanPts, amberPts);
    } else if (msg.type === "REQUEST_REMATCH") {
      if (this.ctx.getWebSockets().length === 2) {
        this.roundNumber++;
        this.startRound();
      }
    } else if (
      msg.type === "LOSER_PICK_ARCHETYPE" &&
      attachment.side === this.loserSide
    ) {
      const pick = String(msg.archetype) as Archetype;
      if (
        pick === "mirrorSymmetric" ||
        pick === "pointSymmetric" ||
        pick === "latchHeavy" ||
        pick === "prepHybrid"
      ) {
        this.customUrlHash = null;
        this.nextArchetype = pick;
        this.roundNumber++;
        this.startRound();
      }
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = ws.deserializeAttachment() as PlayerAttachment | null;
    this.inPrepPhase = false;
    this.broadcastJson({
      type: "OPPONENT_DISCONNECTED",
      side: attachment?.side ?? "unknown",
    });
  }

  private startRound(): void {
    this.hashByTick.clear();
    this.inPrepPhase = true;
    this.cyanPrepReady = false;
    this.amberPrepReady = false;

    const seeds = new Uint32Array(2);
    crypto.getRandomValues(seeds);
    const prepEndsEpochMs = Date.now() + PREP_DURATION_MS;
    this.liveStartEpochMs = prepEndsEpochMs;

    this.broadcastJson({
      type: "MATCH_START",
      round: this.roundNumber,
      cyanWins: this.cyanWins,
      amberWins: this.amberWins,
      seedLo: seeds[0],
      seedHi: seeds[1],
      archetype: this.nextArchetype,
      customUrlHash: this.customUrlHash,
      prepDurationTicks: 200,
      prepEndsEpochMs,
    });
  }

  private relayPrepEdit(
    side: Side,
    kind: number,
    a: number,
    b: number,
    pinRole: number
  ): void {
    const sideCode = side === "cyan" ? 1 : 2;
    const out = new Uint8Array(5);
    out[0] = OPCODE_EVT_PREP_APPLIED;
    out[1] = kind & 0x01;
    out[2] = sideCode & 0x03;
    out[3] = a & 0x3f;
    out[4] = (b & 0x3f) | ((pinRole & 0x03) << 6);

    for (const peer of this.ctx.getWebSockets()) {
      peer.send(out);
    }
  }

  private handlePrepReady(side: Side, ready: boolean): void {
    if (side === "cyan") this.cyanPrepReady = ready;
    else this.amberPrepReady = ready;

    this.broadcastJson({
      type: "PREP_READY_STATE",
      cyanReady: this.cyanPrepReady,
      amberReady: this.amberPrepReady,
    });

    if (this.cyanPrepReady && this.amberPrepReady && this.inPrepPhase) {
      this.inPrepPhase = false;
      this.liveStartEpochMs = Date.now();
      this.broadcastJson({
        type: "LIVE_ROUND_START",
        liveStartEpochMs: this.liveStartEpochMs,
      });
    }
  }

  private handleBinaryDeploy(side: Side, bytes: Uint8Array): void {
    if (this.inPrepPhase && Date.now() >= this.liveStartEpochMs) {
      this.inPrepPhase = false;
    }
    if (this.inPrepPhase) return;

    const clientTick = (bytes[1] << 8) | bytes[2];
    const railIdx = bytes[3] & 0x3f;

    const elapsedMs = Math.max(0, Date.now() - this.liveStartEpochMs);
    const approxServerTick = Math.floor(elapsedMs / TICK_MS);
    const execTick = Math.min(
      65535,
      Math.max(clientTick + INPUT_HORIZON_TICKS, approxServerTick + 1)
    );

    const sideCode = side === "cyan" ? 1 : 2;
    const out = new Uint8Array(4);
    out[0] = OPCODE_EVT_INPUT;
    out[1] = (execTick >>> 8) & 0xff;
    out[2] = execTick & 0xff;
    out[3] = ((sideCode & 0x3) << 6) | railIdx;

    for (const peer of this.ctx.getWebSockets()) {
      peer.send(out);
    }
  }

  private handleHashCheck(side: Side, bytes: Uint8Array): void {
    const tick = (bytes[1] << 8) | bytes[2];
    const hash =
      ((bytes[3] << 24) | (bytes[4] << 16) | (bytes[5] << 8) | bytes[6]) >>> 0;

    const prev = this.hashByTick.get(tick);
    if (!prev) {
      this.hashByTick.set(tick, { side, hash });
      if (this.hashByTick.size > 64) {
        const oldest = this.hashByTick.keys().next().value;
        if (oldest !== undefined) this.hashByTick.delete(oldest);
      }
      return;
    }

    if (prev.side !== side && prev.hash !== hash) {
      const alert = new Uint8Array(3);
      alert[0] = OPCODE_DESYNC_ALERT;
      alert[1] = (tick >>> 8) & 0xff;
      alert[2] = tick & 0xff;
      for (const peer of this.ctx.getWebSockets()) {
        peer.send(alert);
      }
    }
  }

  private recordRoundOutcome(cyanPoints: number, amberPoints: number): void {
    if (cyanPoints > amberPoints) {
      this.cyanWins++;
      this.loserSide = "amber";
    } else if (amberPoints > cyanPoints) {
      this.amberWins++;
      this.loserSide = "cyan";
    } else {
      this.loserSide = this.roundNumber % 2 === 0 ? "cyan" : "amber";
    }

    const matchWinner =
      this.cyanWins >= 3 ? "cyan" : this.amberWins >= 3 ? "amber" : null;

    this.broadcastJson({
      type: "ROUND_SUMMARY",
      round: this.roundNumber,
      cyanWins: this.cyanWins,
      amberWins: this.amberWins,
      loserPicksNext: this.loserSide,
      matchWinner,
    });
  }

  private isSideTaken(target: Side): boolean {
    for (const ws of this.ctx.getWebSockets()) {
      const att = ws.deserializeAttachment() as PlayerAttachment | null;
      if (att?.side === target) return true;
    }
    return false;
  }

  private broadcastJson(payload: Record<string, unknown>): void {
    const encoded = JSON.stringify(payload);
    for (const ws of this.ctx.getWebSockets()) {
      ws.send(encoded);
    }
  }
}
