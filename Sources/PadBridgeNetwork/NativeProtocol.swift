import CryptoKit
import Foundation
import Network
import Security

public enum PacketKind: UInt8 {
    case hello = 1, presence = 2, frame = 3, status = 4, command = 5, error = 6, ping = 7, pong = 8, encrypted = 9
    case videoFrame = 10, frameAck = 11, relayKeepalive = 12
}

public struct Packet {
    public let kind: PacketKind
    public let body: Data
    public init(_ kind: PacketKind, _ body: Data = Data()) { self.kind = kind; self.body = body }
    public var wire: Data {
        let length = UInt32(body.count + 1)
        return Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255), kind.rawValue]) + body
    }
    public static func json(_ kind: PacketKind, _ object: [String: Any]) -> Packet {
        Packet(kind, try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

public enum ProtocolError: Error { case invalidPacket, invalidToken, invalidAddress, authenticationFailed }

public struct PacketDecoder: Sendable {
    public static let maximumLength = 2_097_152
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Packet] {
        buffer.append(data)
        var packets = [Packet]()
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (1...Self.maximumLength).contains(length) else { throw ProtocolError.invalidPacket }
            guard buffer.count >= length + 4 else { break }
            guard let kind = PacketKind(rawValue: buffer[4]) else { throw ProtocolError.invalidPacket }
            packets.append(Packet(kind, Data(buffer[5..<(length + 4)])))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return packets
    }
}

public struct PairingKey {
    private let key: SymmetricKey
    public let room: String
    public static func relayRegistrationKey(token: String) -> String {
        SHA256.hash(data: Data("PadBridge relay registration v3 \(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func managedRelayRoom(token: String) -> String {
        SHA256.hash(data: Data(relayRegistrationKey(token: token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private init(key: SymmetricKey, room: String) { self.key = key; self.room = room }
    public init(token: String) throws {
        guard token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProtocolError.invalidToken
        }
        let material = SHA256.hash(data: Data(token.utf8))
        key = SymmetricKey(data: material)
        room = SHA256.hash(data: Data("PadBridge room \(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func seal(_ packet: Packet) throws -> Packet {
        guard packet.kind != .encrypted && packet.kind != .hello && packet.kind != .presence else { throw ProtocolError.invalidPacket }
        let plain = Data([packet.kind.rawValue]) + packet.body
        return Packet(.encrypted, try AES.GCM.seal(plain, using: key).combined!)
    }
    public func open(_ packet: Packet) throws -> Packet {
        guard packet.kind == .encrypted else { throw ProtocolError.authenticationFailed }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.body), using: key)
        guard let byte = plain.first, let kind = PacketKind(rawValue: byte),
              kind != .encrypted && kind != .hello && kind != .presence else { throw ProtocolError.invalidPacket }
        return Packet(kind, Data(plain.dropFirst()))
    }
    public func session(local: Data, remote: Data) throws -> PairingKey {
        guard local.count == 64, remote.count == 64, local != remote else { throw ProtocolError.authenticationFailed }
        let salt = local.lexicographicallyPrecedes(remote) ? local + remote : remote + local
        return PairingKey(key: HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt,
                          info: Data("PadBridge session v2".utf8), outputByteCount: 32), room: room)
    }
}

public struct SessionCipher {
    private let key: PairingKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    public init(key: PairingKey) { self.key = key }
    public mutating func seal(_ packet: Packet) throws -> Packet {
        guard sent < UInt64.max else { throw ProtocolError.authenticationFailed }
        sent += 1
        var counter = sent.bigEndian
        let bytes = withUnsafeBytes(of: &counter) { Data($0) }
        return try key.seal(Packet(packet.kind, bytes + packet.body))
    }
    public mutating func open(_ packet: Packet) throws -> Packet {
        let result = try key.open(packet)
        guard result.body.count >= 8 else { throw ProtocolError.authenticationFailed }
        let counter = result.body.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard received < UInt64.max, counter == received + 1 else { throw ProtocolError.authenticationFailed }
        received = counter
        return Packet(result.kind, Data(result.body.dropFirst(8)))
    }
}

public struct ServerAddress {
    public let host: String
    public let port: UInt16
    public let webSocket: Bool
    public init(_ text: String) throws {
        guard let url = URLComponents(string: text), let scheme = url.scheme, ["tls", "wss"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let port = UInt16(exactly: url.port ?? (scheme == "wss" ? 443 : 9443)), port != 0 else {
            throw ProtocolError.invalidAddress
        }
        self.host = host; self.port = port
        self.webSocket = scheme == "wss"
    }

    public func connection(token: String) throws -> NWConnection {
        let parameters = relayParameters()
        if !webSocket { return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters) }
        var components = URLComponents()
        components.scheme = "wss"; components.host = host; components.port = Int(port)
        components.path = "/room/" + PairingKey.managedRelayRoom(token: token)
        guard let url = components.url else { throw ProtocolError.invalidAddress }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = PacketDecoder.maximumLength + 4
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return NWConnection(to: .url(url), using: parameters)
    }
}

public func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProtocolError.authenticationFailed }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

public func pairedParameters(token: String) throws -> NWParameters {
    _ = try PairingKey(token: token)
    let tls = NWProtocolTLS.Options()
    let key = Data(token.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data("PadBridge-v2".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    // Apple's external-PSK transport requires this TLS 1.2 cipher suite.
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
}

public func relayParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
    return NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
}

public final class NativePeer {
    private let webSocket: Bool
    private let connection: NWConnection
    private let key: PairingKey
    private let relay: Bool
    private var cipher: SessionCipher?
    private var challenge = Data()
    private var decoder = PacketDecoder()
    private var closed = false
    private var pendingSends = 0
    private var framePending = false
    public var onReady: (() -> Void)?
    public var onPacket: ((Packet) -> Void)?
    public var onClose: ((String) -> Void)?

    public init(connection: NWConnection, token: String, relay: Bool = false, webSocket: Bool = false) throws {
        self.connection = connection
        self.key = try PairingKey(token: token)
        self.relay = relay
        self.webSocket = webSocket
        if !relay { self.cipher = SessionCipher(key: self.key) }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close("Koneksi ditutup.")
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            if self.connection.state != .ready { self.close("Mac/server tidak dapat dijangkau, atau token pairing salah.") }
        }
    }

    @discardableResult public func send(_ packet: Packet, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !closed, pendingSends < 32, packet.body.count < PacketDecoder.maximumLength - 64,
              packet.kind != .frame || !framePending else { completion?(false); return false }
        do {
            let outgoing: Packet
            if relay && (packet.kind == .hello || packet.kind == .relayKeepalive) { outgoing = packet }
            else {
                guard cipher != nil else { completion?(false); return false }
                outgoing = try cipher!.seal(packet)
            }
            pendingSends += 1
            if packet.kind == .frame { framePending = true }
            sendWire(outgoing.wire) { [weak self] error in
                guard let self else { completion?(false); return }
                self.pendingSends -= 1
                if packet.kind == .frame { self.framePending = false }
                completion?(error == nil)
                if let error { self.close(error.localizedDescription) }
            }
            return true
        } catch { close("Enkripsi pesan gagal."); completion?(false); return false }
    }

    public func close(_ reason: String = "Koneksi ditutup.") {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onClose = nil; onPacket = nil; onReady = nil
    }

    private func receive() {
        let process: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, context, complete, error in
            guard let self, !self.closed else { return }
            if self.webSocket, let frame = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               frame.opcode == .close { self.close(); return }
            do {
                for packet in try self.decoder.append(data ?? Data()) {
                    if self.relay && packet.kind == .presence {
                        self.cipher = nil
                        self.challenge = Data(try randomToken().utf8)
                        if packet.body == Data([1]) { try self.sendHandshake(Packet(.ping, self.challenge)) }
                        self.onPacket?(packet)
                    }
                    else if self.relay && packet.kind == .error { self.close("Server menolak sesi. Periksa kunci server atau ketersediaan Mac."); return }
                    else if self.relay {
                        if self.cipher != nil, let decoded = try? self.cipher!.open(packet) { self.onPacket?(decoded) }
                        else {
                            // A previous viewer's in-flight frame can arrive before the new handshake.
                            guard let decoded = try? self.key.open(packet) else {
                                if self.cipher != nil { throw ProtocolError.authenticationFailed }
                                continue
                            }
                            if decoded.kind == .ping && decoded.body.count == 64 && self.challenge.count == 64 {
                                try self.sendHandshake(Packet(.pong, self.challenge + decoded.body))
                            } else if decoded.kind == .pong && decoded.body.count == 128 && Data(decoded.body.suffix(64)) == self.challenge {
                                if self.cipher == nil {
                                    self.cipher = SessionCipher(key: try self.key.session(local: self.challenge, remote: Data(decoded.body.prefix(64))))
                                }
                            } else { throw ProtocolError.authenticationFailed }
                        }
                    } else {
                        guard self.cipher != nil else { throw ProtocolError.authenticationFailed }
                        self.onPacket?(try self.cipher!.open(packet))
                    }
                }
                if (!self.webSocket && complete) || error != nil || data == nil { self.close(error?.localizedDescription ?? "Koneksi terputus.") }
                else { self.receive() }
            } catch { self.close("Token salah atau pesan koneksi tidak valid.") }
        }
        if webSocket { connection.receiveMessage(completion: process) }
        else { connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536, completion: process) }
    }
    private func sendHandshake(_ packet: Packet) throws {
        sendWire(try key.seal(packet).wire) { [weak self] error in
            if let error { self?.close(error.localizedDescription) }
        }
    }
    private func sendWire(_ bytes: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        let context: NWConnection.ContentContext
        if webSocket {
            context = NWConnection.ContentContext(identifier: "padbridge", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        } else { context = .defaultMessage }
        connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed(completion))
    }
    deinit { connection.cancel() }
}
