import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import VirtualDisplayBridge
import PadBridgeNetwork
import ServiceManagement

enum DisplayMode: String, Decodable { case remote, extend }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var server: NativeHost?
    private var token = ""
    private var capture = ScreenCapture()
    private let input = InputController()
    private var virtualDisplay: VirtualDisplaySession?
    private var mode = DisplayMode.remote
    private var captureDetailed = true
    private var switching = false
    private var errorMessage: String?
    private var statusItem: NSStatusItem?
    private var accessibilityItem: NSMenuItem?
    private var connectionItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var handoffPanel: NSPanel?
    private var relaySettings: (ServerAddress, String?)?
    private var activeRelayAddress: String?
    private var bundledRelayAddress: String? { Bundle.main.object(forInfoDictionaryKey: "PadBridgeRelayAddress") as? String }
    private var savedSettings: HostSettings?
    private var assertion: IOPMAssertionID = 0
    private var signalSources = [DispatchSourceSignal]()
    private let testServer = CommandLine.arguments.contains("--test-server")
    private let testKeyboard = CommandLine.arguments.contains("--test-keyboard")
    private let isProbeSession = CommandLine.arguments.contains("--probe-session")
    private var testFrame: Data?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if testServer { token = String(repeating: "0", count: 64) }
            else if isProbeSession { token = try randomToken() }
            else {
                let settings = try HostSettings.load()
                savedSettings = settings; token = settings.token
                if let address = settings.relayAddress, let key = settings.relayKey {
                    relaySettings = (try ServerAddress(address), key)
                    activeRelayAddress = address
                } else if settings.managedRelayDisabled != true, let address = bundledRelayAddress,
                          let endpoint = try? ServerAddress(address) {
                    relaySettings = (endpoint, nil)
                    activeRelayAddress = address
                }
            }
            capture.onError = { [weak self] message in self?.errorMessage = message; self?.input.release(); self?.server?.captureUnavailable() }
            if testServer { testFrame = makeTestFrame() }
            buildMenu()
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { NSApp.terminate(nil) }
                source.resume()
                signalSources.append(source)
            }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), "DeskShift active session" as CFString, &assertion)
            try startServer()
            if isProbeSession { Task { await self.probeSession() } }
            else if !testServer, CommandLine.arguments.contains("--setup") {
                Task { @MainActor in
                    await self.setLoginEnabled(true)
                    if !CGPreflightScreenCaptureAccess() { self.screenPermission() }
                    else if !AXIsProcessTrusted() { self.accessibilityPermission() }
                }
            }
        } catch {
            fputs("DeskShift: \(error.localizedDescription)\n", stderr)
            let alert = NSAlert()
            alert.messageText = "DeskShift tidak dapat dimulai"
            alert.informativeText = "Pengaturan Keychain atau koneksi tidak dapat dibaca. \(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        handoffPanel?.close()
        server?.stop()
        input.release()
        virtualDisplay?.stop()
        virtualDisplay = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = testServer ? "DeskShift Test" : "DeskShift"
        let menu = NSMenu()
        menu.delegate = self
        connectionItem = NSMenuItem(title: "Menyiapkan koneksi lokal…", action: nil, keyEquivalent: "")
        menu.addItem(connectionItem!)
        add("Kode sambungan…", #selector(pairingInfo), to: menu)
        add("Sambungkan server sendiri…", #selector(configureRelay), to: menu)
        add("Putuskan server internet", #selector(disconnectRelay), to: menu)
        add("Ganti kode dan putuskan sesi", #selector(rotateToken), to: menu)
        menu.addItem(.separator())
        add("Remote — layar utama Mac", #selector(remoteMode), to: menu)
        add("Extend — layar tambahan", #selector(extendMode), to: menu)
        menu.addItem(.separator())
        loginItem = add("Jalankan saat login", #selector(toggleLogin), to: menu)
        add("Izin perekaman layar…", #selector(screenPermission), to: menu)
        accessibilityItem = add("Izin Accessibility…", #selector(accessibilityPermission), to: menu)
        menu.addItem(.separator())
        add("Keluar DeskShift", #selector(quit), to: menu)
        statusItem?.menu = menu
    }

    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func pairingInfo() {
        let alert = NSAlert()
        alert.messageText = "Kode sambungan"
        NSApp.activate(ignoringOtherApps: true)
        let local = localIPv4Address(), relay = activeRelayAddress
        guard let address = local ?? relay,
              let code = try? PairingCode(address: address, token: token, relayFallback: local == nil ? nil : relay) else {
            alert.informativeText = "Sambungkan Mac ke Wi-Fi atau Ethernet, lalu buka kode lagi."
            alert.addButton(withTitle: "Tutup")
            alert.runModal()
            return
        }
        if code.relayFallback != nil {
            alert.informativeText = "Tempel kode ini di DeskShift. Aplikasi mencoba koneksi lokal dulu, lalu server pribadimu jika Mac tidak terjangkau."
        } else if code.internet {
            alert.informativeText = "Tempel kode ini di DeskShift untuk menyambung lewat server pribadimu."
        } else {
            alert.informativeText = "Tempel kode ini di DeskShift pada iPad atau iPhone yang satu jaringan dengan Mac."
        }
        alert.informativeText += " Simpan kode ini untuk perangkatmu sendiri."
        let field = NSTextField(wrappingLabelWithString: code.text)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 430
        field.frame = NSRect(x: 0, y: 0, width: 430, height: field.intrinsicContentSize.height)
        alert.accessoryView = field
        alert.addButton(withTitle: "Salin kode")
        if !testServer { alert.addButton(withTitle: "Lewat Akun Apple…") }
        alert.addButton(withTitle: "Tutup")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.text, forType: .string)
        case .alertSecondButtonReturn where !testServer:
            offerPairingHandoff(code)
        default:
            break
        }
    }

    private func offerPairingHandoff(_ code: PairingCode) {
        handoffPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Sambungkan lewat Akun Apple"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let instruction = NSTextField(wrappingLabelWithString: "Di iPad atau iPhone dengan Akun Apple yang sama, buka DeskShift dari Handoff (di Dock iPad atau Pengalih App iPhone). Dekatkan perangkat dan aktifkan Wi-Fi, Bluetooth, serta Handoff. Undangan ini berlaku dua menit selama jendela terbuka.")
        instruction.frame = NSRect(x: 20, y: 16, width: 380, height: 100)
        panel.contentView?.addSubview(instruction)
        let activity = PairingHandoff.makeActivity(for: code)
        panel.userActivity = activity
        handoffPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        activity.becomeCurrent()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === handoffPanel else { return }
        panel.userActivity?.invalidate()
        panel.userActivity = nil
        handoffPanel = nil
    }
    @objc private func configureRelay() {
        let alert = NSAlert()
        alert.messageText = "Server DeskShift milikmu"
        alert.informativeText = "Masukkan alamat TLS dan kunci host server milikmu. Kunci disimpan di Keychain; Mac menyambung kembali saat DeskShift dibuka."
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let address = NSTextField(string: UserDefaults.standard.string(forKey: "relayAddress") ?? "")
        address.placeholderString = "tls://server-milikmu:9443"
        let key = NSSecureTextField(string: "")
        key.placeholderString = "Kunci host server (64 karakter)"
        for field in [address, key] { field.widthAnchor.constraint(equalToConstant: 360).isActive = true; stack.addArrangedSubview(field) }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sambungkan"); alert.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let serverAddress = try ServerAddress(address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try PairingKey(token: key.stringValue)
            if var settings = savedSettings {
                settings.relayAddress = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.relayKey = key.stringValue
                try settings.save(); savedSettings = settings
            }
            relaySettings = (serverAddress, key.stringValue)
            activeRelayAddress = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(address.stringValue, forKey: "relayAddress")
            server?.connectRelay(address: serverAddress, key: key.stringValue)
        } catch {
            let invalid = NSAlert(); invalid.messageText = "Server belum tersimpan atau tersambung"
            invalid.informativeText = "Gunakan tls://hostname:9443 dan kunci host 64 karakter heksadesimal. \(error.localizedDescription)"
            invalid.runModal()
        }
    }
    @objc private func disconnectRelay() {
        relaySettings = nil; activeRelayAddress = nil; server?.disconnectRelay()
        do {
            if var settings = savedSettings {
                settings.relayAddress = nil; settings.relayKey = nil
                settings.managedRelayDisabled = true
                try settings.save(); savedSettings = settings
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "Koneksi diputus, pengaturan lama belum terhapus"
            alert.informativeText = "\(error.localizedDescription) Pengaturan lama bisa menyambung kembali saat aplikasi dibuka ulang."
            alert.runModal()
        }
    }
    @objc private func rotateToken() {
        do {
            let replacement = try randomToken()
            if var settings = savedSettings { settings.token = replacement; try settings.save(); savedSettings = settings }
            token = replacement; input.release(); try startServer()
        }
        catch { errorMessage = error.localizedDescription }
    }
    @objc private func remoteMode() { Task { await setMode(.remote) } }
    @objc private func extendMode() { Task { await setMode(.extend) } }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let status = SMAppService.mainApp.status
        loginItem?.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginItem?.title = status == .requiresApproval ? "Jalankan saat login — menunggu izin macOS" : "Jalankan saat login"
        accessibilityItem?.isHidden = AXIsProcessTrusted()
    }
    @objc private func toggleLogin() {
        let status = SMAppService.mainApp.status
        Task { @MainActor in
            await setLoginEnabled(status != .enabled && status != .requiresApproval)
        }
    }
    @MainActor private func setLoginEnabled(_ enabled: Bool) async {
        do {
            let service = SMAppService.mainApp
            if enabled {
                let status = service.status
                if status != .enabled && status != .requiresApproval {
                    try service.register()
                }
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else { try await service.unregister() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Pengaturan jalankan saat login belum berubah"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc private func screenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func accessibilityPermission() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @MainActor private func setMode(_ desired: DisplayMode) async {
        guard !switching else { return }
        guard !testServer else { errorMessage = "Server pengujian: capture dan input dinonaktifkan."; return }
        guard CGPreflightScreenCaptureAccess() else {
            errorMessage = "Mac belum mengizinkan perekaman layar. Di Mac, izinkan DeskShift di Screen & System Audio Recording, lalu buka ulang DeskShift di Mac."
            return
        }
        switching = true
        let detailed = server?.prefersDetailedCapture ?? true
        defer {
            switching = false
            if let host = server, errorMessage == nil, mode == .remote, captureDetailed != host.prefersDetailedCapture {
                scheduleViewerCapture(for: host, startIfMissing: false)
            }
        }
        input.release()
        await capture.stop()
        server?.captureUnavailable()
        errorMessage = nil
        do {
            if desired == .extend {
                if virtualDisplay == nil {
                    virtualDisplay = try await VirtualDisplaySession.start()
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
                guard let virtualDisplay else { throw appError("Layar virtual tidak tersedia.") }
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw appError("Konfigurasi layar gagal.") }
                let mirror = CGConfigureDisplayMirrorOfDisplay(config, virtualDisplay.displayID, kCGNullDirectDisplay)
                let mainBounds = CGDisplayBounds(CGMainDisplayID())
                let origin = CGConfigureDisplayOrigin(config, virtualDisplay.displayID, Int32(mainBounds.maxX), Int32(mainBounds.minY))
                guard mirror == .success, origin == .success else {
                    CGCancelDisplayConfiguration(config)
                    throw appError("Layar tambahan tidak bisa diatur.")
                }
                guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw appError("Konfigurasi layar ditolak macOS.") }
                input.displayID = virtualDisplay.displayID
            } else {
                virtualDisplay?.stop()
                virtualDisplay = nil
                input.displayID = CGMainDisplayID()
            }
            try await capture.start(displayID: input.displayID, extended: desired == .extend, detailed: detailed)
            mode = desired
            captureDetailed = detailed
        } catch {
            virtualDisplay?.stop()
            virtualDisplay = nil
            input.displayID = CGMainDisplayID()
            mode = .remote
            errorMessage = error.localizedDescription + " Pilih Remote untuk mencoba kembali."
        }
    }

    private func startServer() throws {
        server?.stop()
        let host = NativeHost(token: token)
        host.frame = { [weak self] in guard let self else { return nil }; return self.testServer ? self.testFrame : self.capture.frame() }
        host.rawFrame = { [weak self] in self?.capture.latestRawFrame() }
        capture.onFrame = { [weak host] in host?.publishFrame() }
        if !isProbeSession && !testServer { host.onJPEGRequirementChanged = { [weak self] needed in self?.capture.setJPEGEnabled(needed) } }
        host.status = { [weak self] in
            guard let self else { return [:] }
            let canControl = self.testServer ? self.testKeyboard : AXIsProcessTrusted()
            return ["mode": self.mode.rawValue, "switching": self.switching, "test": self.testServer,
                    "hostName": Host.current().localizedName ?? "Mac",
                    "control": canControl, "accessibilityRequired": !self.testServer && !canControl,
                    "error": self.errorMessage ?? "",
                    "frameAvailable": self.testServer || self.capture.hasFrame,
                    "virtualDisplayAvailable": PBVirtualDisplay.isAvailable()]
        }
        host.command = { [weak self] data, peer in self?.handleCommand(data, from: peer) }
        host.onState = { [weak self] state in self?.connectionItem?.title = state }
        host.onDisconnect = { [weak self, weak host] in
            self?.input.release()
            if let host { self?.scheduleViewerCapture(for: host, startIfMissing: false) }
        }
        host.onViewerConnected = { [weak self, weak host] in
            if let host { self?.scheduleViewerCapture(for: host, startIfMissing: true) }
        }
        server = host
        try host.start()
        if let (address, key) = relaySettings { host.connectRelay(address: address, key: key) }
    }

    private func scheduleViewerCapture(for host: NativeHost, startIfMissing: Bool) {
        Task { @MainActor [weak self, weak host] in
            guard let self, let host, self.server === host, host.hasViewer,
                  !self.testServer, !self.isProbeSession, !self.switching else { return }
            let changeDetail = self.mode == .remote && self.captureDetailed != host.prefersDetailedCapture
            guard changeDetail || (startIfMissing && !self.capture.hasFrame) else { return }
            await self.setMode(self.mode)
        }
    }

    private func handleCommand(_ data: Data, from peer: NativePeer) {
        func fail(_ message: String) { peer.send(.json(.error, ["message": message])) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let action = object["action"] as? String else {
            fail("Perintah tidak valid."); return
        }
        if action == "mode" {
            guard let text = object["mode"] as? String, let desired = DisplayMode(rawValue: text), !switching, !testServer else {
                fail("Mode tidak tersedia atau pergantian layar belum selesai."); return
            }
            Task { @MainActor in await self.setMode(desired) }
        } else if action == "input" {
            guard let object = object["input"] as? [String: Any], let body = try? JSONSerialization.data(withJSONObject: object),
                  let event = try? JSONDecoder().decode(RemoteInput.self, from: body), event.valid else {
                fail("Input tidak valid."); return
            }
            if testServer && testKeyboard {
                fputs("Test input: \(event.action)\n", stderr)
                return
            }
            guard !switching, !testServer, errorMessage == nil, capture.hasFrame, input.send(event) else {
                fail(AXIsProcessTrusted() ? "Tunggu sampai layar Mac siap." : "Izinkan DeskShift di Accessibility pada Mac sekali.")
                return
            }
        } else { fail("Perintah tidak dikenal.") }
    }

    private func appError(_ message: String) -> NSError {
        NSError(domain: "PadBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor private func probeSession() async {
        for selected in [DisplayMode.remote, .extend, .remote] {
            await setMode(selected)
            for _ in 0..<50 {
                if capture.frame() != nil || errorMessage != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard mode == selected, errorMessage == nil, let data = capture.frame(),
                  let image = NSBitmapImageRep(data: data),
                  selected != .extend || (image.pixelsWide == 1600 && image.pixelsHigh == 1200) else {
                fputs("FAIL: \(selected.rawValue) session: \(errorMessage ?? "Tidak ada frame atau ukuran salah.")\n", stderr)
                virtualDisplay?.stop()
                exit(1)
            }
            print("PASS: \(selected.rawValue) session, JPEG \(image.pixelsWide)×\(image.pixelsHigh)")
        }
        await capture.stop()
        NSApp.terminate(nil)
    }

    private func makeTestFrame() -> Data? {
        let image = NSImage(size: NSSize(width: 1200, height: 900))
        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 900).fill()
        NSString(string: "DeskShift / Test frame").draw(at: NSPoint(x: 80, y: 500), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSString(string: "Capture layar dan kontrol Mac dinonaktifkan.").draw(at: NSPoint(x: 80, y: 430), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
