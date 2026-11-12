#!/usr/bin/env node
/**
 * Unified Static Flutter WebAssembly + Live RFC-6455 WebSocket 1v1 Lockstep Room Server.
 *
 * Implements the exact wire contract of `services/arena_edge_rooms` (`POST /api/rooms`
 * and `GET /ws/room/:code`) alongside static Wasm/JS asset serving from `build/web`.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const WEB_ROOT = path.join(__dirname, "apps", "logic_transfer_arena", "build", "web");

const OPCODE_CMD_DEPLOY = 0x01;
const OPCODE_EVT_INPUT = 0x02;
const OPCODE_HASH_CHECK = 0x03;
const OPCODE_DESYNC_ALERT = 0x04;
const OPCODE_CMD_PREP_GATE = 0x05;
const OPCODE_CMD_PREP_WIRE = 0x06;
const OPCODE_EVT_PREP_APPLIED = 0x07;
const OPCODE_CMD_PREP_READY = 0x08;

const TICK_MS = 50;
const INPUT_HORIZON_TICKS = 2;
const PREP_DURATION_MS = 10000;

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".otf": "font/otf",
  ".ttf": "font/ttf",
  ".frag": "text/plain; charset=utf-8",
};

function generateRoomCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.randomBytes(4);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

/** Lightweight RFC-6455 WebSocket wrapper over a raw Node `net.Socket`. */
class RawWsPeer {
  constructor(socket, side) {
    this.socket = socket;
    this.side = side;
    this.closed = false;
    this._rxBuf = Buffer.alloc(0);
    this.onText = null;
    this.onBinary = null;
    this.onClose = null;

    socket.setNoDelay(true);
    socket.on("data", (chunk) => this._consume(chunk));
    socket.on("end", () => this._handleClose());
    socket.on("close", () => this._handleClose());
    socket.on("error", () => this._handleClose());
  }

  sendJson(obj) {
    if (this.closed) return;
    const payload = Buffer.from(JSON.stringify(obj), "utf8");
    this._writeFrame(0x01, payload);
  }

  sendBytes(uint8) {
    if (this.closed) return;
    this._writeFrame(0x02, Buffer.from(uint8));
  }

  _writeFrame(opcode, payload) {
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.alloc(2);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = len;
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    try {
      this.socket.write(Buffer.concat([header, payload]));
    } catch {
      this._handleClose();
    }
  }

  _consume(chunk) {
    this._rxBuf = Buffer.concat([this._rxBuf, chunk]);
    while (this._rxBuf.length >= 2) {
      const b0 = this._rxBuf[0];
      const b1 = this._rxBuf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;

      if (payloadLen === 126) {
        if (this._rxBuf.length < 4) return;
        payloadLen = this._rxBuf.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (this._rxBuf.length < 10) return;
        payloadLen = Number(this._rxBuf.readBigUInt64BE(2));
        offset = 10;
      }

      const maskLen = masked ? 4 : 0;
      if (this._rxBuf.length < offset + maskLen + payloadLen) return;

      const payload = Buffer.from(
        this._rxBuf.subarray(offset + maskLen, offset + maskLen + payloadLen)
      );
      if (masked) {
        const mask = this._rxBuf.subarray(offset, offset + 4);
        for (let i = 0; i < payload.length; i++) {
          payload[i] ^= mask[i & 3];
        }
      }
      this._rxBuf = this._rxBuf.subarray(offset + maskLen + payloadLen);

      if (opcode === 0x08) {
        this._handleClose();
        return;
      } else if (opcode === 0x09) {
        this._writeFrame(0x0a, payload);
      } else if (opcode === 0x01) {
        this.onText?.(payload.toString("utf8"));
      } else if (opcode === 0x02) {
        this.onBinary?.(new Uint8Array(payload));
      }
    }
  }

  _handleClose() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.socket.destroy();
    } catch {}
    this.onClose?.();
  }
}

/** Stateful 1v1 Lockstep Room mirroring `ArenaMatchRoom.ts`. */
class LocalArenaRoom {
  constructor(code) {
    this.code = code;
    this.peers = [];
    this.roundNumber = 1;
    this.cyanWins = 0;
    this.amberWins = 0;
    this.loserSide = null;
    this.nextArchetype = "mirrorSymmetric";
    this.customUrlHash = null;
    this.inPrepPhase = false;
    this.cyanPrepReady = false;
    this.amberPrepReady = false;
    this.liveStartEpochMs = 0;
    this.roundRecorded = false;
    this.hashByTick = new Map();
    this.prepTimer = null;
  }

  hasSide(side) {
    return this.peers.some((p) => !p.closed && p.side === side);
  }

  acceptSocket(socket, boardParam) {
    this.peers = this.peers.filter((p) => !p.closed);
    if (this.peers.length >= 2) {
      socket.write("HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    if (boardParam && boardParam.startsWith("#arena=v1.")) {
      this.customUrlHash = boardParam;
    }

    const side = this.hasSide("cyan") ? "amber" : "cyan";
    const peer = new RawWsPeer(socket, side);
    this.peers.push(peer);

    peer.onBinary = (bytes) => this.onBinary(peer, bytes);
    peer.onText = (txt) => this.onText(peer, txt);
    peer.onClose = () => this.onPeerClose(peer);

    peer.sendJson({
      type: "WELCOME",
      roomCode: this.code,
      side,
      playersConnected: this.peers.length,
    });
    this.broadcastJson({
      type: "ROOM_STATUS",
      roomCode: this.code,
      playersConnected: this.peers.length,
    });

    if (this.peers.length === 2) {
      this.startRound();
    }
  }

  startRound() {
    clearTimeout(this.prepTimer);
    this.hashByTick.clear();
    this.inPrepPhase = true;
    this.cyanPrepReady = false;
    this.amberPrepReady = false;
    this.roundRecorded = false;

    const seeds = new Uint32Array(2);
    crypto.randomFillSync(seeds);
    const prepEndsEpochMs = Date.now() + PREP_DURATION_MS;
    this.liveStartEpochMs = prepEndsEpochMs;

    this.broadcastJson({
      type: "MATCH_START",
      roomCode: this.code,
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

    this.prepTimer = setTimeout(() => {
      if (this.inPrepPhase) {
        this.launchLiveTransfer();
      }
    }, PREP_DURATION_MS);
  }

  launchLiveTransfer() {
    if (!this.inPrepPhase) return;
    clearTimeout(this.prepTimer);
    this.inPrepPhase = false;
    this.liveStartEpochMs = Date.now();
    this.broadcastJson({
      type: "LIVE_ROUND_START",
      liveStartEpochMs: this.liveStartEpochMs,
    });
  }

  onBinary(peer, bytes) {
    if (bytes.length === 0) return;
    switch (bytes[0]) {
      case OPCODE_CMD_DEPLOY:
        if (bytes.length >= 4) this.handleBinaryDeploy(peer.side, bytes);
        break;
      case OPCODE_HASH_CHECK:
        if (bytes.length >= 7) this.handleHashCheck(peer.side, bytes);
        break;
      case OPCODE_CMD_PREP_GATE:
        if (bytes.length >= 3 && this.inPrepPhase) {
          this.relayPrepEdit(peer.side, 0, bytes[1] & 0x3f, bytes[2] & 0x3f, 0);
        }
        break;
      case OPCODE_CMD_PREP_WIRE:
        if (bytes.length >= 4 && this.inPrepPhase) {
          this.relayPrepEdit(
            peer.side,
            1,
            bytes[1] & 0x3f,
            bytes[2] & 0x3f,
            bytes[3] & 0x03
          );
        }
        break;
      case OPCODE_CMD_PREP_READY:
        if (bytes.length >= 2 && this.inPrepPhase) {
          if (peer.side === "cyan") this.cyanPrepReady = bytes[1] !== 0;
          else this.amberPrepReady = bytes[1] !== 0;
          this.broadcastJson({
            type: "PREP_READY_STATE",
            cyanReady: this.cyanPrepReady,
            amberReady: this.amberPrepReady,
          });
          if (this.cyanPrepReady && this.amberPrepReady) {
            this.launchLiveTransfer();
          }
        }
        break;
    }
  }

  onText(peer, text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    if (msg.type === "PING") {
      peer.sendJson({ type: "PONG", clientTs: msg.clientTs });
    } else if (msg.type === "SET_CUSTOM_BOARD" && typeof msg.urlHash === "string") {
      if (msg.urlHash.startsWith("#arena=v1.")) {
        this.customUrlHash = msg.urlHash;
        if (this.peers.filter((p) => !p.closed).length === 2) {
          this.startRound();
        }
      }
    } else if (msg.type === "ROUND_RESULT" && !this.roundRecorded) {
      this.roundRecorded = true;
      this.recordRoundOutcome(Number(msg.cyanPoints || 0), Number(msg.amberPoints || 0));
    } else if (msg.type === "REQUEST_REMATCH") {
      if (this.peers.filter((p) => !p.closed).length === 2) {
        this.roundNumber++;
        this.startRound();
      }
    } else if (msg.type === "LOSER_PICK_ARCHETYPE" && peer.side === this.loserSide) {
      const pick = String(msg.archetype);
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

  relayPrepEdit(side, kind, a, b, pinRole) {
    const sideCode = side === "cyan" ? 1 : 2;
    const out = new Uint8Array(5);
    out[0] = OPCODE_EVT_PREP_APPLIED;
    out[1] = kind & 0x01;
    out[2] = sideCode & 0x03;
    out[3] = a & 0x3f;
    out[4] = (b & 0x3f) | ((pinRole & 0x03) << 6);
    for (const p of this.peers) {
      if (!p.closed) p.sendBytes(out);
    }
  }

  handleBinaryDeploy(side, bytes) {
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

    for (const p of this.peers) {
      if (!p.closed) p.sendBytes(out);
    }
  }

  handleHashCheck(side, bytes) {
    const tick = (bytes[1] << 8) | bytes[2];
    const hash =
      ((bytes[3] << 24) | (bytes[4] << 16) | (bytes[5] << 8) | bytes[6]) >>> 0;
    const prev = this.hashByTick.get(tick);
    if (!prev) {
      this.hashByTick.set(tick, { side, hash });
      if (this.hashByTick.size > 64) {
        const first = this.hashByTick.keys().next().value;
        if (first !== undefined) this.hashByTick.delete(first);
      }
      return;
    }
    if (prev.side !== side && prev.hash !== hash) {
      const alert = new Uint8Array(3);
      alert[0] = OPCODE_DESYNC_ALERT;
      alert[1] = (tick >>> 8) & 0xff;
      alert[2] = tick & 0xff;
      for (const p of this.peers) {
        if (!p.closed) p.sendBytes(alert);
      }
    }
  }

  recordRoundOutcome(cyanPts, amberPts) {
    if (cyanPts > amberPts) {
      this.cyanWins++;
      this.loserSide = "amber";
    } else if (amberPts > cyanPts) {
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

  onPeerClose(peer) {
    clearTimeout(this.prepTimer);
    this.peers = this.peers.filter((p) => !p.closed);
    this.inPrepPhase = false;
    this.broadcastJson({
      type: "OPPONENT_DISCONNECTED",
      side: peer.side,
      playersConnected: this.peers.length,
    });
  }

  broadcastJson(obj) {
    for (const p of this.peers) {
      if (!p.closed) p.sendJson(obj);
    }
  }
}

const rooms = new Map();

function getOrCreateRoom(code) {
  const key = code.toUpperCase();
  let room = rooms.get(key);
  if (!room) {
    room = new LocalArenaRoom(key);
    rooms.set(key, room);
  }
  return room;
}

const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Upgrade");
  res.setHeader("Cache-Control", "no-cache");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  const parsedUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);

  if (parsedUrl.pathname === "/api/rooms" && req.method === "POST") {
    let code = generateRoomCode();
    while (rooms.has(code)) code = generateRoomCode();
    getOrCreateRoom(code);
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ roomCode: code, wsPath: `/ws/room/${code}` }));
    return;
  }

  if (parsedUrl.pathname === "/api/health") {
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ service: "logic-transfer-arena", activeRooms: rooms.size }));
    return;
  }

  let relPath = decodeURIComponent(parsedUrl.pathname);
  if (relPath === "/") relPath = "/index.html";
  const safePath = path.normalize(relPath).replace(/^(\.\.(\/|\\|$))+/, "");
  const fullPath = path.join(WEB_ROOT, safePath);

  if (!fullPath.startsWith(WEB_ROOT)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.stat(fullPath, (err, stat) => {
    if (err || !stat.isFile()) {
      res.writeHead(404);
      res.end("Not Found");
      return;
    }
    const ext = path.extname(fullPath).toLowerCase();
    res.writeHead(200, {
      "Content-Type": MIME_TYPES[ext] || "application/octet-stream",
      "Content-Length": stat.size,
    });
    fs.createReadStream(fullPath).pipe(res);
  });
});

server.on("upgrade", (req, socket) => {
  const parsedUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const match = parsedUrl.pathname.match(/^\/ws\/room\/([A-Za-z0-9_-]{3,16})$/);
  const wsKey = req.headers["sec-websocket-key"];

  if (!match || !wsKey) {
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const acceptKey = crypto
    .createHash("sha1")
    .update(wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");

  socket.write(
    [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${acceptKey}`,
      "\r\n",
    ].join("\r\n")
  );

  const room = getOrCreateRoom(match[1]);
  room.acceptSocket(socket, parsedUrl.searchParams.get("board"));
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    `Serving Logic Transfer Arena (Wasm + Live WS Rooms) at http://localhost:${PORT}`
  );
});
