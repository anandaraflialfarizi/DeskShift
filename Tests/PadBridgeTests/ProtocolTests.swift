import XCTest
import Network
@preconcurrency import PadBridgeNetwork
@testable import PadBridge

final class ProtocolTests: XCTestCase {
    func testHostSettingsSurviveReloadAndDoNotOverwriteInvalidCredentials() throws {
        let account = "test-host-\(UUID().uuidString)"
        defer { try? SecureStore.delete(account: account) }
        var original = try HostSettings.load(account: account)
        let token = original.token
        XCTAssertEqual(try HostSettings.load(account: account).token, token)
        original.relayAddress = "tls://example.com:9443"
        original.relayKey = String(repeating: "a", count: 64)
        try original.save(account: account)
        let restored = try HostSettings.load(account: account)
        XCTAssertEqual(restored.relayAddress, original.relayAddress)
        XCTAssertEqual(restored.relayKey, original.relayKey)
        let oldProfile = try JSONSerialization.data(withJSONObject: ["token": token, "allowControl": false])
        XCTAssertEqual(try JSONDecoder().decode(HostSettings.self, from: oldProfile).token, token)
        original.relayAddress = nil; original.relayKey = nil
        try original.save(account: account)
        XCTAssertNil(try HostSettings.load(account: account).relayAddress)
        XCTAssertEqual(try HostSettings.load(account: account).token, token)
        let invalid = Data("invalid saved settings".utf8)
        try SecureStore.write(invalid, account: account)
        XCTAssertThrowsError(try HostSettings.load(account: account))
        XCTAssertEqual(try SecureStore.read(account: account), invalid)
    }
    func testKeychainSavedSettingsRoundTripAndDelete() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? SecureStore.delete(account: account) }
        XCTAssertNil(try SecureStore.read(account: account))
        let original = Data("first test credential".utf8)
        try SecureStore.write(original, account: account)
        XCTAssertEqual(try SecureStore.read(account: account), original)
        let replacement = Data("replacement test credential".utf8)
        try SecureStore.write(replacement, account: account)
        XCTAssertEqual(try SecureStore.read(account: account), replacement)
        try SecureStore.delete(account: account)
        XCTAssertNil(try SecureStore.read(account: account))
    }
    func testFragmentedAndCoalescedPackets() throws {
        var decoder = PacketDecoder()
        let packet = Packet(.frame, Data([1, 2, 3])).wire
        XCTAssertTrue(try decoder.append(Data(packet.prefix(3))).isEmpty)
        let result = try decoder.append(Data(packet.dropFirst(3)) + Packet(.ping).wire)
        XCTAssertEqual(result.map(\.kind), [.frame, .ping])
        XCTAssertEqual(result.first?.body, Data([1, 2, 3]))
    }
    func testRejectsInvalidPacketLengthsAndTypes() {
        for data in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 99])] {
            var decoder = PacketDecoder()
            XCTAssertThrowsError(try decoder.append(data))
        }
    }
    func testEncryptionAuthenticationAndRandomNonces() throws {
        let key = try PairingKey(token: String(repeating: "a", count: 64))
        let wrong = try PairingKey(token: String(repeating: "b", count: 64))
        let packet = Packet.json(.command, ["action": "mode", "mode": "extend"])
        let sealed = try key.seal(packet)
        XCTAssertEqual(try key.open(sealed).body, packet.body)
        XCTAssertNotEqual(try key.seal(packet).body, sealed.body)
        XCTAssertThrowsError(try wrong.open(sealed))
        var changed = sealed.body; changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try key.open(Packet(.encrypted, changed)))
        XCTAssertThrowsError(try key.open(packet))
        XCTAssertThrowsError(try PairingKey(token: "short"))
        XCTAssertNotEqual(key.room, String(repeating: "a", count: 64))
        XCTAssertEqual(try randomToken().count, 64)
        XCTAssertNotEqual(try randomToken(), try randomToken())
    }
    func testServerAddressValidation() throws {
        XCTAssertEqual(try ServerAddress("tls://example.com:9443").port, 9443)
        for bad in ["http://example.com", "tls://user:password@example.com", "tls://example.com/path", "tls://example.com:0", "tls://example.com?secret=a"] {
            XCTAssertThrowsError(try ServerAddress(bad), bad)
        }
    }
    func testPairingCodeCarriesAddressAndToken() throws {
        let token = String(repeating: "ab", count: 32)
        let local = try PairingCode(address: "192.168.1.42", token: token)
        let pasted = try PairingCode("\n\(local.text.uppercased())\t")
        XCTAssertEqual(pasted.address, "192.168.1.42")
        XCTAssertEqual(pasted.token, token)
        XCTAssertFalse(pasted.internet)

        let remote = try PairingCode(address: "tls://example.com:9443", token: token)
        XCTAssertTrue(try PairingCode(remote.text).internet)
        XCTAssertEqual(try PairingCode(remote.text).address, remote.address)
        for bad in [token, "PB2 192.168.1.42 \(token)", "PB1 mac.local \(token)",
                    "PB1 192.168.1.500 \(token)", "PB1 192.168.1.42 ab", "PB1 http://example.com \(token)",
                    "PB1 tls://user@example.com \(token)", "PB1 192.168.1.42 \(token) extra"] {
            XCTAssertThrowsError(try PairingCode(bad))
        }
    }
    func testPairingCodeCarriesLocalAndRelayAddresses() throws {
        let token = String(repeating: "ab", count: 32)
        let relay = "tls://example.com:9443"
        let original = try PairingCode(address: "192.168.1.42", token: token, relayFallback: relay)
        let decoded = try PairingCode(original.text)
        XCTAssertEqual(decoded.address, original.address)
        XCTAssertEqual(decoded.token, token)
        XCTAssertEqual(decoded.relayFallback, relay)
        XCTAssertFalse(decoded.internet)
        XCTAssertNil(try PairingCode("PB1 192.168.1.42 \(token)").relayFallback)
        XCTAssertThrowsError(try PairingCode("PB1 192.168.1.42 \(token) \(relay)"))
        XCTAssertThrowsError(try PairingCode("PB2 \(relay) \(token) \(relay)"))
        XCTAssertThrowsError(try PairingCode("PB2 192.168.1.42 \(token) http://example.com"))
    }
    func testPairingHandoffValidatesCodeAndExpiry() throws {
        let now = Date.now
        let code = try PairingCode(address: "192.168.1.42", token: String(repeating: "ab", count: 32))
        let activity = PairingHandoff.makeActivity(for: code, now: now)
        XCTAssertTrue(activity.isEligibleForHandoff)
        XCTAssertFalse(activity.isEligibleForSearch)
        XCTAssertFalse(activity.isEligibleForPublicIndexing)
        XCTAssertEqual(try PairingHandoff.read(activity, now: now).text, code.text)
        XCTAssertThrowsError(try PairingHandoff.read(activity, now: now.addingTimeInterval(120)))
        activity.userInfo = ["pairing-code": "broken", "expires": now.addingTimeInterval(60)]
        XCTAssertThrowsError(try PairingHandoff.read(activity, now: now))
    }
    func testFreshSessionKeysAndReplayRejection() throws {
        let key = try PairingKey(token: String(repeating: "a", count: 64))
        let local = Data(String(repeating: "b", count: 64).utf8), remote = Data(String(repeating: "c", count: 64).utf8)
        var sender = SessionCipher(key: try key.session(local: local, remote: remote))
        var receiver = SessionCipher(key: try key.session(local: remote, remote: local))
        let sealed = try sender.seal(Packet(.command, Data("control".utf8)))
        XCTAssertEqual(try receiver.open(sealed).body, Data("control".utf8))
        XCTAssertThrowsError(try receiver.open(sealed))
        var otherSession = SessionCipher(key: try key.session(local: local, remote: Data(String(repeating: "d", count: 64).utf8)))
        XCTAssertThrowsError(try otherSession.open(sealed))
    }
    func testInputValidation() throws {
        func valid(_ value: String) throws -> Bool { try JSONDecoder().decode(RemoteInput.self, from: Data(value.utf8)).valid }
        XCTAssertTrue(try valid("{\"action\":\"down\",\"x\":0,\"y\":1}"))
        XCTAssertFalse(try valid("{\"action\":\"down\",\"x\":1.1,\"y\":0}"))
        XCTAssertFalse(try valid("{\"action\":\"scroll\",\"delta\":1001}"))
        XCTAssertFalse(try valid("{\"action\":\"key\",\"code\":\"ExecuteWhatever\"}"))
        XCTAssertFalse(try valid("{\"action\":\"text\",\"text\":\"\"}"))
    }
    @MainActor func testRealPairedTLSConnection() async throws {
        let token = String(repeating: "a", count: 64)
        let received = expectation(description: "Encrypted command reached paired peer over TLS")
        let ready = expectation(description: "listener ready")
        let listener = try NWListener(using: pairedParameters(token: token), on: .any)
        var server: NativePeer?
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                server = try! NativePeer(connection: connection, token: token)
                server?.onPacket = { packet in
                    if packet.kind == .command && packet.body == Data("test".utf8) { received.fulfill() }
                }
                server?.onClose = { reason in XCTFail("Server: \(reason)") }
                server?.start()
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let client = try NativePeer(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: pairedParameters(token: token)), token: token)
        client.onReady = { client.send(Packet(.command, Data("test".utf8))) }
        client.onClose = { reason in XCTFail(reason) }
        client.start()
        await fulfillment(of: [received], timeout: 8)
        client.onClose = nil; client.onReady = nil
        server?.onClose = nil
        client.close(); server?.close(); listener.cancel()
    }

    @MainActor func testNativePeersCompleteFreshSessionThroughOpaqueRelay() async throws {
        let token = String(repeating: "a", count: 64)
        let listener = try NWListener(using: pairedParameters(token: token), on: .any)
        let ready = expectation(description: "relay listener ready")
        let received = expectation(description: "authenticated command crossed opaque relay")
        var connections = [UUID: NWConnection]()
        var decoders = [UUID: PacketDecoder]()
        var registered = Set<UUID>()
        func receive(_ id: UUID) {
            guard let connection = connections[id] else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, _ in
                MainActor.assumeIsolated {
                    do {
                        for packet in try decoders[id]!.append(data ?? Data()) {
                            if packet.kind == .hello {
                                registered.insert(id)
                                if registered.count == 2 {
                                    for item in connections.values { item.send(content: Packet(.presence, Data([1])).wire, completion: .idempotent) }
                                }
                            } else {
                                XCTAssertEqual(packet.kind, .encrypted)
                                for (other, item) in connections where other != id {
                                    item.send(content: packet.wire, completion: .idempotent)
                                }
                            }
                        }
                        if !complete { receive(id) }
                    } catch { XCTFail("Invalid relay packet: \(error)") }
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let id = UUID(); connections[id] = connection; decoders[id] = PacketDecoder()
                connection.start(queue: .main); receive(id)
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let peers = try (0..<2).map { _ in
            try NativePeer(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: pairedParameters(token: token)), token: token, relay: true)
        }
        for (index, peer) in peers.enumerated() {
            peer.onReady = { [weak peer] in peer?.send(.json(.hello, ["role": index == 0 ? "host" : "viewer"])) }
            peer.onClose = { reason in XCTFail(reason) }
            peer.start()
        }
        peers[1].onPacket = { packet in
            if packet.kind == .command && packet.body == Data("relay test".utf8) { received.fulfill() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if peers[0].send(Packet(.command, Data("relay test".utf8))) { timer.invalidate() }
        }
        await fulfillment(of: [received], timeout: 5)
        timer.invalidate()
        for peer in peers { peer.onClose = nil; peer.close() }
        connections.values.forEach { $0.cancel() }; listener.cancel()
    }

    @MainActor func testWrongPairingTokenCannotCompleteTLS() async throws {
        let listener = try NWListener(using: pairedParameters(token: String(repeating: "a", count: 64)), on: .any)
        let ready = expectation(description: "listener ready")
        let rejected = expectation(description: "wrong token rejected")
        var server: NativePeer?
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                server = try! NativePeer(connection: connection, token: String(repeating: "a", count: 64))
                server?.onPacket = { _ in XCTFail("Unauthenticated input reached host") }
                server?.start()
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let wrong = String(repeating: "b", count: 64)
        let client = try NativePeer(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: pairedParameters(token: wrong)), token: wrong)
        client.onReady = { XCTFail("Wrong token authenticated") }
        client.onClose = { _ in rejected.fulfill() }
        client.start()
        await fulfillment(of: [rejected], timeout: 15)
        client.onClose = nil; client.close(); server?.close(); listener.cancel()
    }
}
