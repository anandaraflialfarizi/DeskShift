import Foundation
import Network
import PadBridgeNetwork

final class NativeHost {
    private let token: String
    private var listener: NWListener?
    private var pending = [UUID: NativePeer]()
    private var direct: NativePeer?
    private var relay: NativePeer?
    private var remoteViewer = false
    private var relayViewerAuthenticated = false
    private var relaySettings: (ServerAddress, String?)?
    private var generation = 0
    private var frameTimer: Timer?
    private var statusTimer: Timer?
    private var videos = [ObjectIdentifier: VideoSender]()
    private var captureWasAvailable = false
    var frame: (() -> Data?)?
    var rawFrame: (() -> RawVideoFrame?)?
    var onJPEGRequirementChanged: ((Bool) -> Void)?
    var status: (() -> [String: Any])?
    var command: ((Data, NativePeer) -> Void)?
    var onState: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onViewerConnected: (() -> Void)?
    var hasViewer: Bool { direct != nil || (remoteViewer && relayViewerAuthenticated) }
    var prefersDetailedCapture: Bool { direct != nil || !hasViewer }

    init(token: String) { self.token = token }

    func start() throws {
        let parameters = try pairedParameters(token: token)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: 8765)
        self.listener = listener
        listener.service = NWListener.Service(name: "PadBridge — \(Host.current().localizedName ?? "Mac")", type: "_padbridge._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.onState?("Lokal siap · port 8765") }
            if case .failed(let error) = state { self?.onState?("Lokal: \(error.localizedDescription)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.pending.count < 4 else { connection.cancel(); return }
            do {
                let id = UUID()
                let peer = try NativePeer(connection: connection, token: self.token)
                self.pending[id] = peer
                peer.onReady = { [weak self, weak peer] in
                    guard let self, let peer else { return }
                    self.pending.removeValue(forKey: id)
                    guard self.direct == nil else { peer.close("Mac sedang dipakai perangkat lain."); return }
                    self.direct = peer
                    self.onViewerConnected?()
                    self.updateJPEGRequirement()
                    self.sendStatus()
                }
                peer.onPacket = { [weak self, weak peer] packet in
                    guard let self, let peer else { return }
                    self.handle(packet, from: peer)
                }
                peer.onClose = { [weak self, weak peer] _ in
                    guard let self else { return }
                    self.pending.removeValue(forKey: id)
                    if let peer { self.removeVideo(peer) }
                    if self.direct === peer { self.direct = nil; self.onDisconnect?(); self.updateJPEGRequirement() }
                }
                peer.start()
            } catch { connection.cancel() }
        }
        listener.start(queue: .main)
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let targets = [self.direct, self.remoteViewer ? self.relay : nil].compactMap { $0 }.filter { self.videos[ObjectIdentifier($0)] == nil }
            guard !targets.isEmpty, let frame = self.frame?() else { return }
            let packet = Packet(.frame, frame)
            targets.forEach { $0.send(packet) }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sendStatus()
            if let (address, key) = self.relaySettings, !address.webSocket {
                self.relay?.send(Packet(key == nil ? .relayKeepalive : .ping))
            }
            Array(self.videos.values).forEach { $0.checkTimeout() }
        }
        updateJPEGRequirement()
    }

    func connectRelay(address: ServerAddress, key: String?) {
        generation += 1
        if let relay { removeVideo(relay) }
        relaySettings = (address, key)
        relay?.close(); relay = nil; remoteViewer = false
        openRelay(generation: generation)
    }

    func disconnectRelay() {
        generation += 1; relaySettings = nil; remoteViewer = false
        if let relay { removeVideo(relay) }
        relay?.close(); relay = nil
        onDisconnect?()
        onState?("Internet tidak tersambung")
    }

    private func openRelay(generation expected: Int) {
        guard generation == expected, let (address, hostKey) = relaySettings else { return }
        do {
            let connection = try address.connection(token: token)
            let peer = try NativePeer(connection: connection, token: token, relay: true, webSocket: address.webSocket)
            relay = peer
            peer.onReady = { [weak self, weak peer] in
                guard let self else { return }
                let managed = hostKey == nil
                peer?.send(.json(.hello, ["role": "host",
                                         "room": managed ? PairingKey.managedRelayRoom(token: self.token) : try! PairingKey(token: self.token).room,
                                         "key": hostKey ?? PairingKey.relayRegistrationKey(token: self.token),
                                         "version": managed ? 3 : 2]))
                self.onState?("Internet: menunggu perangkat")
            }
            peer.onPacket = { [weak self, weak peer] packet in
                guard let self, let peer else { return }
                if packet.kind == .presence {
                    self.relayViewerAuthenticated = false
                    self.remoteViewer = packet.body == Data([1])
                    self.onState?(self.remoteViewer ? "Internet: perangkat tersambung" : "Internet: menunggu perangkat")
                    if !self.remoteViewer { self.removeVideo(peer); self.onDisconnect?() }
                    self.updateJPEGRequirement()
                    self.sendStatus()
                } else {
                    if !self.relayViewerAuthenticated {
                        self.relayViewerAuthenticated = true
                        self.onViewerConnected?()
                    }
                    self.handle(packet, from: peer)
                }
            }
            peer.onClose = { [weak self, weak peer] _ in
                guard let self, self.generation == expected else { return }
                self.remoteViewer = false; self.onDisconnect?()
                if let peer { self.removeVideo(peer) }
                self.updateJPEGRequirement()
                self.onState?("Internet terputus · mencoba lagi")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openRelay(generation: expected) }
            }
            peer.start()
        } catch { onState?(error.localizedDescription) }
    }

    private func handle(_ packet: Packet, from peer: NativePeer) {
        if packet.kind == .ping { peer.send(Packet(.pong)); return }
        if packet.kind == .frameAck {
            guard packet.body.count == 8 else { peer.close("Acknowledgement video tidak valid."); return }
            videos[ObjectIdentifier(peer)]?.acknowledge(packet.body.reduce(0) { ($0 << 8) | UInt64($1) })
            return
        }
        guard packet.kind == .command, packet.body.count <= 16_384 else { peer.close("Pesan tidak valid."); return }
        if let object = try? JSONSerialization.jsonObject(with: packet.body) as? [String: Any], object["action"] as? String == "video", object["codec"] as? String == "jpeg" {
            removeVideo(peer); updateJPEGRequirement(); return
        }
        if let object = try? JSONSerialization.jsonObject(with: packet.body) as? [String: Any], object["action"] as? String == "video", object["codec"] as? String == "h264", rawFrame?() != nil {
            let id = ObjectIdentifier(peer)
            guard videos[id] == nil else { return }
            let video = VideoSender(peer: peer, detailed: peer === direct)
            video.onFailure = { [weak self, weak peer] message in
                guard let self, let peer else { return }
                self.removeVideo(peer)
                peer.send(.json(.error, ["message": message]))
                self.updateJPEGRequirement()
            }
            videos[id] = video
            updateJPEGRequirement()
            publishFrame()
            return
        }
        command?(packet.body, peer)
    }

    private func sendStatus() {
        guard var status = status?() else { return }
        status["h264"] = rawFrame?() != nil
        let packet = Packet.json(.status, status)
        direct?.send(packet)
        if remoteViewer { relay?.send(packet) }
    }

    func stop() {
        frameTimer?.invalidate(); statusTimer?.invalidate()
        listener?.cancel(); listener = nil
        disconnectRelay()
        direct?.close(); direct = nil
        let waiting = Array(pending.values)
        pending.removeAll()
        waiting.forEach { $0.close() }
        videos.values.forEach { $0.stop() }; videos.removeAll()
    }

    func publishFrame() {
        guard let frame = rawFrame?() else { return }
        if !captureWasAvailable { captureWasAvailable = true; sendStatus() }
        videos.values.forEach { $0.offer(frame) }
    }
    func captureUnavailable() {
        captureWasAvailable = false
        videos.values.forEach { $0.discardLatest() }
        sendStatus()
    }
    private func removeVideo(_ peer: NativePeer) { videos.removeValue(forKey: ObjectIdentifier(peer))?.stop() }
    private func updateJPEGRequirement() {
        let peers = [direct, remoteViewer ? relay : nil].compactMap { $0 }
        onJPEGRequirementChanged?(peers.contains { videos[ObjectIdentifier($0)] == nil })
    }
}
