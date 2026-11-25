import Foundation
import PadBridgeNetwork

struct HostSettings: Codable {
    var token: String
    var relayAddress: String?
    var relayKey: String?
    var managedRelayDisabled: Bool?

    static func load(account: String = "mac-host") throws -> HostSettings {
        if let data = try SecureStore.read(account: account) {
            let settings = try JSONDecoder().decode(Self.self, from: data)
            _ = try PairingKey(token: settings.token)
            if let address = settings.relayAddress {
                _ = try ServerAddress(address)
                guard let key = settings.relayKey else { throw ProtocolError.invalidToken }
                _ = try PairingKey(token: key)
            }
            return settings
        }
        let settings = HostSettings(token: try randomToken())
        try settings.save(account: account)
        return settings
    }

    func save(account: String = "mac-host") throws {
        try SecureStore.write(JSONEncoder().encode(self), account: account)
    }
}
