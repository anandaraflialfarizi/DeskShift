import Foundation
import Network

struct SavedConnection: Codable {
    let token: String
    let address: String
    let internet: Bool
    let relayFallback: String?
    var name: String
    let serviceName: String?
    let serviceDomain: String?

    init(code: PairingCode) {
        token = code.token
        address = code.address
        internet = code.internet
        relayFallback = code.relayFallback
        name = code.address
        serviceName = nil
        serviceDomain = nil
    }

    var endpoint: NWEndpoint? {
        guard !internet, let serviceName, let serviceDomain else { return nil }
        return .service(name: serviceName, type: "_padbridge._tcp", domain: serviceDomain, interface: nil)
    }
}
