#!/usr/bin/env python3
"""PadBridge's private TLS relay. Uses only Python's standard library."""
import argparse
import asyncio
import hmac
import hashlib
import json
import os
import re
import ssl
import struct

MAX_PACKET = 2_097_152
HELLO, PRESENCE, ERROR, ENCRYPTED, KEEPALIVE = 1, 2, 6, 9, 12
HEX_KEY = re.compile(r"[a-f0-9]{64}\Z")


def packet(kind, body=b""):
    return struct.pack("!IB", len(body) + 1, kind) + body


async def read_packet(reader, maximum=MAX_PACKET):
    header = await asyncio.wait_for(reader.readexactly(4), 45)
    length = struct.unpack("!I", header)[0]
    if not 1 <= length <= maximum:
        raise ValueError("invalid packet length")
    body = await asyncio.wait_for(reader.readexactly(length), 15)
    return body[0], body[1:]


class Peer:
    def __init__(self, writer):
        self.writer = writer
        self.lock = asyncio.Lock()

    async def send(self, kind, body=b""):
        async with self.lock:
            self.writer.write(packet(kind, body))
            await asyncio.wait_for(self.writer.drain(), 10)

    def close(self):
        self.writer.close()


class Relay:
    def __init__(self, host_key, maximum_rooms=16, managed=False):
        if managed and host_key:
            raise ValueError("Managed relay must run separately from a private relay")
        if (host_key or not managed) and not HEX_KEY.fullmatch(host_key):
            raise ValueError("PADBRIDGE_HOST_KEY must contain 64 lowercase hexadecimal characters")
        self.host_key = host_key
        self.managed = managed
        self.rooms = {}
        self.connections = 0
        self.maximum_rooms = maximum_rooms

    async def accept(self, reader, writer):
        if self.connections >= 64:
            writer.close()
            return
        self.connections += 1
        peer = Peer(writer)
        room_id, role, registered = None, None, False
        try:
            kind, body = await asyncio.wait_for(read_packet(reader, 4096), 8)
            if kind != HELLO:
                raise ValueError("expected hello")
            hello = json.loads(body)
            if not isinstance(hello, dict):
                raise ValueError("invalid hello")
            room_id, role = hello.get("room"), hello.get("role")
            version = hello.get("version")
            if version not in (2, 3) or not isinstance(room_id, str) or not HEX_KEY.fullmatch(room_id):
                raise ValueError("invalid room")
            if role == "host":
                candidate = hello.get("key", "")
                if not isinstance(candidate, str) or not HEX_KEY.fullmatch(candidate):
                    raise ValueError("host authentication failed")
                if version == 3:
                    verified = self.managed and hmac.compare_digest(hashlib.sha256(candidate.encode()).hexdigest(), room_id)
                else:
                    verified = bool(self.host_key) and hmac.compare_digest(candidate, self.host_key)
                if not verified:
                    raise ValueError("host authentication failed")
                if room_id in self.rooms or len(self.rooms) >= self.maximum_rooms:
                    raise ValueError("room unavailable")
                self.rooms[room_id] = {"host": peer, "viewer": None, "managed": version == 3}
                registered = True
                await peer.send(PRESENCE, b"\x00")
            elif role == "viewer":
                room = self.rooms.get(room_id)
                if room is None and self.managed:
                    fallback = hello.get("managedRoom")
                    if isinstance(fallback, str) and HEX_KEY.fullmatch(fallback):
                        candidate = self.rooms.get(fallback)
                        if candidate and candidate["managed"]:
                            room_id, room = fallback, candidate
                if room is None or room["viewer"] is not None:
                    raise ValueError("host unavailable or viewer already connected")
                room["viewer"] = peer
                registered = True
                await peer.send(PRESENCE, b"\x01")
                await room["host"].send(PRESENCE, b"\x01")
            else:
                raise ValueError("invalid role")
            while True:
                kind, body = await read_packet(reader)
                room = self.rooms.get(room_id)
                if room is None or room.get(role) is not peer:
                    break
                if kind == KEEPALIVE and not body and room["managed"] and role == "host":
                    continue
                if kind != ENCRYPTED or len(body) < 29:
                    raise ValueError("only encrypted application packets may be forwarded")
                other = room["viewer" if role == "host" else "host"]
                if other is not None:
                    await other.send(kind, body)
        except (ValueError, UnicodeError, KeyError, TypeError):
            try:
                await peer.send(ERROR, b'{"message":"Session rejected"}')
            except (ConnectionError, OSError, asyncio.TimeoutError):
                pass
        except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            if registered:
                room = self.rooms.get(room_id)
                if room and room.get(role) is peer:
                    if role == "host":
                        self.rooms.pop(room_id, None)
                        if room["viewer"] is not None:
                            room["viewer"].close()
                    else:
                        room["viewer"] = None
                        try:
                            await room["host"].send(PRESENCE, b"\x00")
                        except (ConnectionError, OSError, asyncio.TimeoutError):
                            room["host"].close()
            self.connections -= 1
            peer.close()
            try:
                await asyncio.wait_for(writer.wait_closed(), 2)
            except (ConnectionError, OSError, asyncio.TimeoutError):
                pass


async def run(args):
    relay = Relay(os.environ.get("PADBRIDGE_HOST_KEY", ""), managed=args.managed)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(args.cert, args.key)
    server = await asyncio.start_server(relay.accept, args.listen, args.port, ssl=context,
                                        ssl_handshake_timeout=8, limit=65_536)
    print(f"PadBridge relay listening on {args.listen}:{args.port}; TLS enabled", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--managed", action="store_true", help="Enable room-specific registration for a managed pilot")
    parser.add_argument("--cert", required=True, help="PEM certificate chain for your own hostname")
    parser.add_argument("--key", required=True, help="PEM private key")
    arguments = parser.parse_args()
    try:
        asyncio.run(run(arguments))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Relay configuration error: {error}\n")
    except KeyboardInterrupt:
        pass
