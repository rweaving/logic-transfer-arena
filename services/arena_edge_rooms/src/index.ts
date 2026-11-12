import { ArenaMatchRoom } from "./ArenaMatchRoom";

export { ArenaMatchRoom };

export interface Env {
  ARENA_ROOMS: DurableObjectNamespace<ArenaMatchRoom>;
}

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Upgrade",
};

function generateRoomCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // POST /api/rooms -> generates a quick 4-char duel invite code.
    if (url.pathname === "/api/rooms" && request.method === "POST") {
      const code = generateRoomCode();
      return Response.json(
        {
          roomCode: code,
          wsPath: `/ws/room/${code}`,
        },
        { headers: CORS_HEADERS }
      );
    }

    // GET /ws/room/:code -> upgrades WebSocket inside stateful Durable Object room.
    const match = url.pathname.match(/^\/ws\/room\/([A-Za-z0-9_-]{3,16})$/);
    if (match) {
      const roomCode = match[1].toUpperCase();
      const id = env.ARENA_ROOMS.idFromName(roomCode);
      const stub = env.ARENA_ROOMS.get(id);
      return stub.fetch(request);
    }

    return Response.json(
      { service: "logic-transfer-arena-edge", status: "ok" },
      { headers: CORS_HEADERS }
    );
  },
};
