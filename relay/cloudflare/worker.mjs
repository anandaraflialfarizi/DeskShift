const hex = /^[0-9a-f]{64}$/;
const maxPacket = 2_097_152;
const hello = 1, presence = 2, encrypted = 9;

function status(flag) {
  return Uint8Array.of(0, 0, 0, 2, presence, flag);
}

export function decodePacket(message) {
  if (!(message instanceof ArrayBuffer) || message.byteLength < 5 || message.byteLength > maxPacket + 4) return null;
  const length = new DataView(message).getUint32(0);
  if (length !== message.byteLength - 4) return null;
  return { kind: new Uint8Array(message)[4], body: new Uint8Array(message, 5) };
}

export async function verifyHost(key, room) {
  if (typeof key !== "string" || !hex.test(key)) return false;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return Array.from(new Uint8Array(digest), value => value.toString(16).padStart(2, "0")).join("") === room;
}

export default {
  fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/health" && request.method === "GET") return new Response("PadBridge relay\n");
    const match = /^\/room\/([0-9a-f]{64})$/.exec(path);
    if (!match || match[1] !== env.PADBRIDGE_ROOM) return new Response("Not found", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
    return env.ROOMS.get(env.ROOMS.idFromName(match[1])).fetch(request);
  }
};

export class Room {
  constructor(state, env) {
    this.state = state;
    this.room = env.PADBRIDGE_ROOM;
  }

  sockets() { return this.state.getWebSockets().filter(socket => socket.readyState === 1); }
  find(role, except) { return this.sockets().find(socket => socket !== except && socket.deserializeAttachment()?.role === role); }

  fetch() {
    for (const socket of this.sockets()) {
      const info = socket.deserializeAttachment();
      if (!info?.role && Date.now() - (info?.at ?? 0) > 8_000) socket.close(1008, "Expired");
    }
    if (this.sockets().length >= 4) return new Response("Busy", { status: 429 });
    const [client, server] = Object.values(new WebSocketPair());
    this.state.acceptWebSocket(server);
    server.serializeAttachment({ at: Date.now() });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket, message) {
    const packet = decodePacket(message);
    if (!packet) { socket.close(1008, "Invalid packet"); return; }
    const info = socket.deserializeAttachment();
    if (info?.role) {
      if (packet.kind !== encrypted || packet.body.length < 29) { socket.close(1008, "Encrypted packet required"); return; }
      this.find(info.role === "host" ? "viewer" : "host", socket)?.send(message);
      return;
    }
    if (packet.kind !== hello || packet.body.length > 4095 || Date.now() - (info?.at ?? 0) > 8_000) { socket.close(1008, "Invalid hello"); return; }
    let data;
    try { data = JSON.parse(new TextDecoder().decode(packet.body)); } catch { socket.close(1008, "Invalid hello"); return; }
    if (data?.role === "host" && data.version === 3 && data.room === this.room && await verifyHost(data.key, this.room)) {
      if (socket.readyState !== 1 || this.find("host", socket)) { socket.close(1008, "Host already connected"); return; }
      socket.serializeAttachment({ role: "host" });
      socket.send(status(0));
    } else if (data?.role === "viewer" && data.version === 2 && data.managedRoom === this.room) {
      const host = this.find("host", socket);
      if (!host || this.find("viewer", socket)) { socket.close(1008, "Host unavailable"); return; }
      socket.serializeAttachment({ role: "viewer" });
      socket.send(status(1));
      host.send(status(1));
    } else { socket.close(1008, "Session rejected"); }
  }

  webSocketClose(socket) {
    const role = socket.deserializeAttachment()?.role;
    if (role === "host") this.find("viewer", socket)?.close(1001, "Host disconnected");
    if (role === "viewer") this.find("host", socket)?.send(status(0));
  }
  webSocketError(socket) { socket.close(1011, "Socket failure"); }
}
