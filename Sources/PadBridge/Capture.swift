import AppKit
import CoreImage
import PadBridgeNetwork
import ScreenCaptureKit

struct RawVideoFrame {
    let sequence: UInt64
    let pixel: CVPixelBuffer
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "PadBridge.capture", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var activeStream: ObjectIdentifier?
    private var raw: RawVideoFrame?
    private var sequence: UInt64 = 0
    private var jpeg: Data?
    private var updatedAt: Date?
    private var jpegEnabled = true
    private var lastJPEG = Date.distantPast
    private var notificationPending = false
    var onError: ((String) -> Void)?
    var onFrame: (() -> Void)?

    static func frameSize(width: Int, height: Int, pointPixelScale: Float, extended: Bool, detailed: Bool = true) -> CGSize {
        let pixelsPerPoint = extended ? 1 : max(1, Double(pointPixelScale))
        let widthInPixels = Double(width) * pixelsPerPoint
        let heightInPixels = Double(height) * pixelsPerPoint
        let landscapeLimit: (width: Double, height: Double)
        if extended { landscapeLimit = (1600, 1200) }
        else if detailed { landscapeLimit = (2752, 2064) }
        else { landscapeLimit = (1920, 1200) }
        let portrait = !extended && height > width
        let limit = portrait ? (landscapeLimit.height, landscapeLimit.width) : landscapeLimit
        let scale = min(1, limit.0 / widthInPixels, limit.1 / heightInPixels)
        return CGSize(width: max(2, Int(widthInPixels * scale) / 2 * 2),
                      height: max(2, Int(heightInPixels * scale) / 2 * 2))
    }

    func start(displayID: CGDirectDisplayID, extended: Bool = false, detailed: Bool = true) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "PadBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Layar tidak ditemukan. Coba pilih mode lagi."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let size = Self.frameSize(width: display.width, height: display.height,
                                  pointPixelScale: filter.pointPixelScale, extended: extended, detailed: detailed)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let candidate = SCStream(filter: filter, configuration: config, delegate: self)
        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = candidate
        lock.withLock { activeStream = ObjectIdentifier(candidate) }
        do { try await candidate.startCapture() }
        catch { stream = nil; clear(); throw error }
    }

    func stop() async {
        let previous = stream
        stream = nil
        clear()
        try? await previous?.stopCapture()
    }

    func frame() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard fresh else { return nil }
        return jpeg
    }
    func latestRawFrame() -> RawVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return fresh ? raw : nil
    }
    var hasFrame: Bool { latestRawFrame() != nil }
    private var fresh: Bool { updatedAt.map { Date().timeIntervalSince($0) < 5 } ?? false }

    func setJPEGEnabled(_ enabled: Bool) {
        lock.lock(); jpegEnabled = enabled; lock.unlock()
        if enabled {
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let frame = self.raw, id = self.activeStream; self.lock.unlock()
                if let frame, let id { self.makeJPEG(frame.pixel, streamID: id) }
            }
        }
    }

    private func clear() {
        lock.lock(); defer { lock.unlock() }
        activeStream = nil; raw = nil; jpeg = nil; updatedAt = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let isCurrent = activeStream == ObjectIdentifier(stream); lock.unlock()
        guard isCurrent else { return }
        clear()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onError?(error.localizedDescription)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let id = ObjectIdentifier(stream)
        lock.lock(); let isCurrent = activeStream == id; lock.unlock()
        guard isCurrent, type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .idle {
            lock.lock(); if activeStream == id && raw != nil { updatedAt = Date() }; lock.unlock()
            return
        }
        guard status == .complete, let pixel = sample.imageBuffer else {
            lock.lock(); if activeStream == id { raw = nil; jpeg = nil; updatedAt = nil }; lock.unlock()
            return
        }
        lock.lock()
        guard activeStream == id else { lock.unlock(); return }
        sequence += 1
        raw = RawVideoFrame(sequence: sequence, pixel: pixel); updatedAt = Date()
        let needsJPEG = jpegEnabled && Date().timeIntervalSince(lastJPEG) >= 0.095
        let notify = !notificationPending
        notificationPending = true
        lock.unlock()
        if notify {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.notificationPending = false; self.lock.unlock()
                self.onFrame?()
            }
        }
        if needsJPEG { makeJPEG(pixel, streamID: id) }
    }
    private func makeJPEG(_ pixel: CVPixelBuffer, streamID: ObjectIdentifier) {
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixel)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var frame: Data?
            for quality in [0.84, 0.65, 0.45, 0.25] {
                guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
                      data.count < PacketDecoder.maximumLength - 64 else { continue }
                frame = data
                break
            }
            lock.lock(); defer { lock.unlock() }
            if activeStream == streamID { jpeg = frame; lastJPEG = Date() }
        }
    }
}
