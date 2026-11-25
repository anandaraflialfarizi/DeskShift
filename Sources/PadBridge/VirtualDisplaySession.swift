import Foundation
import CoreGraphics

final class VirtualDisplaySession {
    private let process: Process
    private let lifetime: Pipe
    private var stopped = false
    let displayID: CGDirectDisplayID

    private init(process: Process, lifetime: Pipe, displayID: CGDirectDisplayID) {
        self.process = process
        self.lifetime = lifetime
        self.displayID = displayID
    }

    static func start() async throws -> VirtualDisplaySession {
        // A fresh process avoids CoreGraphics caching display modes before creation.
        let process = Process()
        let output = Pipe()
        let lifetime = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--virtual-display-helper"]
        process.standardOutput = output
        process.standardInput = lifetime
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = await Task.detached {
            var result = Data()
            while result.count < 128 {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                result.append(chunk)
                if result.contains(10) { break }
            }
            return result
        }.value
        timeout.cancel()
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let id = UInt32(line), id != 0, process.isRunning else {
            if process.isRunning { process.terminate() }
            throw NSError(domain: "PadBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Helper layar virtual gagal. Coba pilih Extend lagi; lihat log host untuk detail."])
        }
        return VirtualDisplaySession(process: process, lifetime: lifetime, displayID: id)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? lifetime.fileHandleForWriting.close()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { child.terminate() }
        }
    }

    deinit { stop() }
}
