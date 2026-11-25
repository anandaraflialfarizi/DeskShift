import Foundation
import Network

public struct PairingCode {
    public let address: String
    public let token: String
    public let relayFallback: String?
    public var internet: Bool { address.hasPrefix("tls://") || address.hasPrefix("wss://") }

    public init(address: String, token: String, relayFallback: String? = nil) throws {
        guard address.utf8.count <= 300, !address.contains(where: \.isWhitespace) else { throw ProtocolError.invalidAddress }
        if address.hasPrefix("tls://") || address.hasPrefix("wss://") {
            guard relayFallback == nil else { throw ProtocolError.invalidAddress }
            _ = try ServerAddress(address)
        } else if IPv4Address(address) == nil {
            throw ProtocolError.invalidAddress
        }
        if let relayFallback {
            guard relayFallback.utf8.count <= 300, !relayFallback.contains(where: \.isWhitespace) else { throw ProtocolError.invalidAddress }
            _ = try ServerAddress(relayFallback)
        }
        let token = token.lowercased()
        _ = try PairingKey(token: token)
        self.address = address
        self.token = token
        self.relayFallback = relayFallback
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 512 else { throw ProtocolError.invalidPacket }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard let tag = fields.first?.uppercased() else { throw ProtocolError.invalidPacket }
        switch (tag, fields.count) {
        case ("PB1", 3):
            try self.init(address: String(fields[1]), token: String(fields[2]))
        case ("PB2", 4):
            try self.init(address: String(fields[1]), token: String(fields[2]), relayFallback: String(fields[3]))
        default: throw ProtocolError.invalidPacket
        }
    }

    public var text: String {
        if let relayFallback { return "PB2 \(address) \(token) \(relayFallback)" }
        return "PB1 \(address) \(token)"
    }
}
