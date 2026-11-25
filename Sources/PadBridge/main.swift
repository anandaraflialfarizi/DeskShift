import AppKit
import ApplicationServices
import PadBridgeNetwork
import ServiceManagement
import VirtualDisplayBridge

if CommandLine.arguments.contains("--virtual-display-helper") {
    signal(SIGTERM, SIG_DFL)
    signal(SIGINT, SIG_DFL)
    do {
        var display: PBVirtualDisplay? = try PBVirtualDisplay.make()
        print(display!.displayID)
        fflush(stdout)
        DispatchQueue.global().async {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            DispatchQueue.main.async {
                display = nil
                exit(0)
            }
        }
        dispatchMain()
    } catch {
        fputs("Virtual display helper: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--managed-room") {
    do { print(PairingKey.managedRelayRoom(token: try HostSettings.load().token)) }
    catch { fputs("PadBridge: \(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Screen Recording: \(CGPreflightScreenCaptureAccess())")
    print("Start at login: \(SMAppService.mainApp.status == .enabled)")
    print("Accessibility: \(AXIsProcessTrusted())")
    print("Virtual display API: \(PBVirtualDisplay.isAvailable())")
    exit(0)
}

if CommandLine.arguments.contains("--probe-virtual-display") {
    do {
        let display = try PBVirtualDisplay.make()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let bounds = CGDisplayBounds(display.displayID)
        guard display.displayID != 0, bounds.width == 1600, bounds.height == 1200 else {
            fputs("FAIL: virtual display has unexpected bounds \(bounds)\n", stderr)
            exit(1)
        }
        print("PASS: virtual display \(display.displayID), \(Int(bounds.width))×\(Int(bounds.height))")
        withExtendedLifetime(display) { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--probe-capture") {
    guard CGPreflightScreenCaptureAccess() else {
        fputs("FAIL: Screen Recording belum diizinkan.\n", stderr)
        exit(1)
    }
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        let capture = ScreenCapture()
        var display: VirtualDisplaySession?
        do {
            if CommandLine.arguments.contains("--extend") {
                display = try await VirtualDisplaySession.start()
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            let id = display?.displayID ?? CGMainDisplayID()
            try await capture.start(displayID: id, extended: display != nil)
            var frame: Data?
            for _ in 0..<50 {
                frame = capture.frame()
                if frame != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let frame, let bitmap = NSBitmapImageRep(data: frame) else {
                throw NSError(domain: "PadBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tidak ada frame JPEG dalam 5 detik."])
            }
            print("PASS: \(display == nil ? "remote" : "extend") capture, JPEG \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(frame.count) bytes")
            await capture.stop()
            display?.stop()
            display = nil
            if CommandLine.arguments.contains("--extend") {
                func online() -> Bool {
                    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
                    var count: UInt32 = 0
                    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return true }
                    return ids.prefix(Int(count)).contains(id)
                }
                for _ in 0..<50 {
                    if !online() { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !online() else {
                    throw NSError(domain: "PadBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Layar virtual belum dilepas setelah sesi ditutup."])
                }
                print("PASS: virtual display removed after session end")
            }
            exit(0)
        } catch {
            await capture.stop()
            display?.stop()
            display = nil
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    probeApp.run()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
