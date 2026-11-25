import SwiftUI
import Network

@main
struct PadBridgeApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

@MainActor final class iPadSession: ObservableObject {
    @Published var image: UIImage?
    @Published var connected = false
    @Published var connecting = false
    @Published var message = ""
    @Published var mode = "remote"
    @Published var control = false
    @Published var accessibilityRequired = false
    @Published var captureFailed = false
    @Published var switching = false
    @Published var testing = false
    @Published var frames = 0
    @Published var savedConnection: SavedConnection?
    private var pendingProfile: SavedConnection?
    private var saveError: String?
    private var peer: NativePeer?
    private var heartbeat: Timer?
    private var lastPacket = Date()
    private var lastFrame = Date.distantPast
    private var renderer = ScreenRenderer()
    private var connectionEpoch = 0
    private var videoRequested = false
    private var usingH264 = false
    private var videoDisabled = false
    private var lastVideoSequence: UInt64 = 0
    private var hostHasFrame = false
    var onDisconnect: (() -> Void)?

    init() {
        do {
            if let data = try SecureStore.read(account: "ipad-connection") {
                savedConnection = try JSONDecoder().decode(SavedConnection.self, from: data)
            }
        } catch { message = "Mac tersimpan belum bisa dibaca dari Keychain. \(error.localizedDescription)" }
    }

    func reconnectSaved() {
        guard let saved = savedConnection else { return }
        connect(saved)
    }

    func forgetSaved() {
        do { try SecureStore.delete(account: "ipad-connection"); savedConnection = nil; saveError = nil; message = "" }
        catch { message = "Mac tersimpan belum terhapus. \(error.localizedDescription)" }
    }

    func connect(code: String) {
        do { connect(SavedConnection(code: try PairingCode(code))) }
        catch { message = "Kode tidak valid. Salin kode lengkap dari menu PadBridge di Mac." }
    }

    private func connect(_ profile: SavedConnection, relayAddress: String? = nil) {
        disconnect()
        renderer = ScreenRenderer(); videoRequested = false; usingH264 = false; videoDisabled = false; lastVideoSequence = 0
        saveError = nil
        do {
            let token = profile.token, address = relayAddress ?? profile.address
            let internet = profile.internet || relayAddress != nil
            let relayFallback = internet ? nil : profile.relayFallback
            let key = try PairingKey(token: token)
            let connection: NWConnection
            var webSocket = false
            if internet {
                let server = try ServerAddress(address)
                connection = try server.connection(token: token)
                webSocket = server.webSocket
            } else if let endpoint = profile.endpoint {
                connection = NWConnection(to: endpoint, using: try pairedParameters(token: token))
            } else {
                let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { throw ProtocolError.invalidAddress }
                connection = NWConnection(host: NWEndpoint.Host(host), port: 8765, using: try pairedParameters(token: token))
            }
            let peer = try NativePeer(connection: connection, token: token, relay: internet, webSocket: webSocket)
            self.peer = peer
            pendingProfile = profile
            connecting = true; message = internet ? "Menghubungkan lewat server PadBridge…" : "Menghubungkan ke Mac…"
            lastPacket = Date(); lastFrame = .distantPast; frames = 0
            peer.onReady = { [weak peer] in
                if internet {
                    peer?.send(.json(.hello, ["role": "viewer", "room": key.room,
                                             "managedRoom": PairingKey.managedRelayRoom(token: token), "version": 2]))
                }
            }
            peer.onPacket = { [weak self, weak peer] packet in
                guard let self, let peer, self.peer === peer else { return }
                self.receive(packet)
            }
            peer.onClose = { [weak self, weak peer] reason in
                guard let self, let peer, self.peer === peer else { return }
                let failedToConnect = !self.connected
                if failedToConnect, let relayFallback {
                    self.connect(profile, relayAddress: relayFallback)
                    return
                }
                self.disconnect()
                if failedToConnect && !internet {
                    self.message = "Mac belum terjangkau. Cek jaringan yang sama dan izin Local Network di iPad, atau salin kode terbaru dari Mac."
                } else { self.message = reason }
            }
            peer.start()
            if relayFallback != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak peer] in
                    guard let self, let peer, self.peer === peer, self.connecting else { return }
                    peer.close("Mac belum merespons di jaringan lokal.")
                }
            }
            heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastPacket) > 12 { self.disconnect(); self.message = "Koneksi terputus. Hubungkan kembali ke Mac."; return }
                    if Date().timeIntervalSince(self.lastFrame) > 5 { self.image = nil; self.control = false }
                    self.peer?.send(Packet(.ping))
                }
            }
        } catch { message = "Sambungan tidak valid. Salin kode terbaru dari menu PadBridge di Mac." }
    }

    private func receive(_ packet: Packet) {
        lastPacket = Date()
        switch packet.kind {
        case .frame:
            guard !usingH264 || videoDisabled else { return }
            let epoch = connectionEpoch
            renderer.jpeg(packet.body) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.connectionEpoch == epoch, self.hostHasFrame, !self.usingH264 || self.videoDisabled else { return }
                    if case .success(let image) = result { self.image = UIImage(cgImage: image); self.lastFrame = Date(); self.frames += 1 }
                    else { self.disconnect(); self.message = "Frame dari Mac tidak valid." }
                }
            }
        case .videoFrame:
            do {
                let frame = try EncodedVideoFrame(data: packet.body)
                if videoDisabled { acknowledge(frame.sequence); return }
                usingH264 = true
                let epoch = connectionEpoch
                renderer.h264(frame) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.connectionEpoch == epoch else { return }
                        switch result {
                        case .success(let image):
                            if frame.sequence > self.lastVideoSequence && !self.videoDisabled && self.hostHasFrame {
                                self.image = UIImage(cgImage: image); self.lastFrame = Date(); self.frames += 1; self.lastVideoSequence = frame.sequence
                            }
                            self.acknowledge(frame.sequence)
                        case .failure:
                            self.videoDisabled = true
                            self.peer?.send(.json(.command, ["action": "video", "codec": "jpeg"]))
                            self.message = "Decode H.264 gagal; memakai JPEG."
                        }
                    }
                }
            } catch { disconnect(); message = "Paket video tidak valid." }
        case .status:
            guard let state = try? JSONSerialization.jsonObject(with: packet.body) as? [String: Any],
                  let mode = state["mode"] as? String, ["remote", "extend"].contains(mode) else { return }
            connected = true; connecting = false
            self.mode = mode; switching = state["switching"] as? Bool ?? false
            control = state["control"] as? Bool ?? false
            accessibilityRequired = state["accessibilityRequired"] as? Bool ?? false
            testing = state["test"] as? Bool ?? false
            if let pending = pendingProfile {
                pendingProfile = nil
                if !testing {
                    do {
                        var verified = pending
                        if let name = state["hostName"] as? String, !name.isEmpty { verified.name = name }
                        try SecureStore.write(JSONEncoder().encode(verified), account: "ipad-connection")
                        savedConnection = verified
                    } catch { saveError = "Terhubung, tetapi pairing belum tersimpan. \(error.localizedDescription)" }
                }
            }
            let hostError = state["error"] as? String ?? ""
            captureFailed = !hostError.isEmpty
            message = hostError.isEmpty ? (saveError ?? "") : hostError
            hostHasFrame = state["frameAvailable"] as? Bool ?? false
            if !hostHasFrame { image = nil; control = false }
            if !testing, state["h264"] as? Bool == true, state["frameAvailable"] as? Bool == true, !videoRequested {
                videoRequested = peer?.send(.json(.command, ["action": "video", "codec": "h264"])) == true
            }
        case .error:
            let object = try? JSONSerialization.jsonObject(with: packet.body) as? [String: String]
            message = object?["message"] ?? "Mac menolak perintah."
        case .presence:
            if packet.body != Data([1]) { connected = false; connecting = true; image = nil; control = false; message = "Menunggu Mac tersambung ke server…" }
        case .pong: break
        default: break
        }
    }

    func selectMode(_ value: String) {
        guard !switching else { return }
        release(); switching = true
        peer?.send(.json(.command, ["action": "mode", "mode": value]))
    }
    func sendInput(_ object: [String: Any]) {
        guard connected, control, !switching else { return }
        if peer?.send(.json(.command, ["action": "input", "input": object])) != true { message = "Input menunggu koneksi. Coba lagi." }
    }
    func release() { sendInput(["action": "release"]) }
    private func acknowledge(_ sequence: UInt64) {
        var value = sequence.bigEndian
        peer?.send(Packet(.frameAck, withUnsafeBytes(of: &value) { Data($0) }))
    }
    func disconnect() {
        connectionEpoch += 1
        hostHasFrame = false
        pendingProfile = nil
        accessibilityRequired = false
        captureFailed = false
        release()
        let old = peer; peer = nil
        old?.onClose = nil; old?.close()
        heartbeat?.invalidate(); heartbeat = nil
        connected = false; connecting = false; control = false; image = nil
    }
    func background() { disconnect(); message = "Sesi ditutup saat aplikasi masuk latar belakang." }
}

struct ConnectionView: View {
    @StateObject private var session = iPadSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var keyboard = false
    @State private var fullScreen = false

    var body: some View {
        NavigationStack {
            Group {
                if session.connected {
                    VStack(spacing: 12) {
                        if !fullScreen {
                            HStack {
                                Picker("Layar Mac", selection: Binding(get: { session.mode }, set: { session.selectMode($0) })) {
                                    Text("Remote").tag("remote"); Text("Extend").tag("extend")
                                }.pickerStyle(.segmented).frame(maxWidth: 300).disabled(session.switching || session.testing)
                                Spacer()
                                keyboardButton
                                fullScreenButton
                            }
                        }
                        if session.testing { Text("Mode pengujian · bukan layar Mac").font(.callout).foregroundStyle(.secondary) }
                        if session.accessibilityRequired {
                            Text("Izinkan PadBridge di Accessibility pada Mac sekali agar mouse dan keyboard bisa dipakai.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !session.message.isEmpty {
                            Text(session.message).font(.callout).foregroundStyle(.red).accessibilityIdentifier("session-message")
                            if session.captureFailed {
                                Button("Mulai ulang tampilan") { session.selectMode(session.mode) }
                                    .disabled(session.switching || session.testing)
                            }
                        }
                        NativeScreen(image: session.image, enabled: session.control && !session.switching, send: session.sendInput)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 8))
                            .accessibilityLabel("Layar Mac").accessibilityIdentifier("remote-screen")
                            .accessibilityValue(session.image == nil ? "Menunggu frame" : "Frame diterima")
                        if keyboard && session.control && !session.switching {
                            RemoteKeyboard(send: session.sendInput).frame(height: 44).padding(.horizontal, fullScreen ? 8 : 0)
                        }
                        if !fullScreen && !keyboard {
                            ViewThatFits(in: .horizontal) {
                                shortcuts.fixedSize(horizontal: true, vertical: false)
                                ScrollView(.horizontal) { shortcuts }.fixedSize(horizontal: false, vertical: true)
                            }.disabled(!session.control || session.switching)
                        }
                    }
                    .padding(fullScreen ? 0 : 16)
                    .overlay(alignment: .topTrailing) {
                        if fullScreen {
                            HStack(spacing: 2) { keyboardButton; fullScreenButton }
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                } else {
                    Form {
                        if let saved = session.savedConnection {
                            Section("Mac tersimpan") {
                                Button(saved.name.isEmpty ? "Hubungkan ke Mac tersimpan" : "Hubungkan ke \(saved.name)") { session.reconnectSaved() }
                                    .disabled(session.connecting).accessibilityIdentifier("connect-saved")
                                Button("Lupakan Mac ini", role: .destructive) { session.forgetSaved(); code = "" }
                                    .disabled(session.connecting)
                            }
                        }
                        Section {
                            SecureField("Kode sambungan", text: $code)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.go).onSubmit(connectWithCode)
                                .disabled(session.connecting)
                                .accessibilityIdentifier("pairing-code")
                            Button("Hubungkan ke Mac", action: connectWithCode)
                                .disabled(session.connecting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("connect-button")
                        } header: {
                            Text(session.savedConnection == nil ? "Sambungkan Mac" : "Kode baru")
                        } footer: {
                            Text("Di menu PadBridge pada Mac, buka Kode sambungan, lalu tempel kodenya di sini.")
                        }
                        if session.connecting {
                            Section {
                                ProgressView(session.message)
                                Button("Batal") { session.disconnect(); session.message = "" }
                            }
                        } else if !session.message.isEmpty {
                            Text(session.message).foregroundStyle(.red).accessibilityIdentifier("connection-message")
                        }
                    }
                }
            }
            .navigationTitle("PadBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(fullScreen)
            .toolbar {
                if session.connected { ToolbarItem(placement: .topBarTrailing) { Button("Putuskan") { session.disconnect(); session.message = ""; keyboard = false } } }
            }
            .onChange(of: session.connected) { _, connected in
                if connected { code = "" }
                else { keyboard = false; fullScreen = false }
            }
            .onChange(of: session.control) { _, control in if !control { keyboard = false } }
            .onChange(of: scenePhase) { _, phase in if phase == .background { session.background() } }
            .onContinueUserActivity(PairingHandoff.activityType) { activity in
                guard !session.connected, !session.connecting else { return }
                do { session.connect(code: try PairingHandoff.read(activity).text) }
                catch { session.message = "Sambungan Handoff sudah tidak berlaku. Buka lagi Lewat Akun Apple di Mac." }
            }
        }
    }

    private var keyboardButton: some View {
        Button {
            keyboard.toggle()
        } label: {
            Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(keyboard ? "Tutup keyboard" : "Keyboard")
        .accessibilityIdentifier("remote-keyboard")
        .disabled(!session.control || session.switching)
    }

    private var fullScreenButton: some View {
        Button {
            fullScreen.toggle()
        } label: {
            Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(fullScreen ? "Keluar layar penuh" : "Layar penuh")
        .accessibilityIdentifier("remote-fullscreen")
        .disabled(session.image == nil && !fullScreen)
    }

    private var shortcuts: some View {
        HStack {
            ForEach([("Esc", "Escape"), ("Tab", "Tab"), ("←", "ArrowLeft"), ("↑", "ArrowUp"), ("↓", "ArrowDown"), ("→", "ArrowRight"), ("Enter", "Enter")], id: \.0) { title, key in
                Button { session.sendInput(["action": "key", "code": key]) } label: {
                    Text(title).frame(minWidth: 28, minHeight: 34)
                }
            }
            Button("Gulir ↑") { session.sendInput(["action": "scroll", "delta": 400]) }
            Button("Gulir ↓") { session.sendInput(["action": "scroll", "delta": -400]) }
        }.buttonStyle(.bordered).controlSize(.large)
    }

    private func connectWithCode() {
        guard !session.connecting, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.connect(code: code)
    }
}
