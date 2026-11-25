import XCTest
@preconcurrency import CoreVideo
import CoreImage
import Network
import PadBridgeNetwork
@testable import PadBridge

final class VideoTests: XCTestCase {
    func testCaptureFitsViewerBudgetWithoutChangingAspectOrUpscaling() {
        XCTAssertEqual(ScreenCapture.frameSize(width: 1512, height: 982, pointPixelScale: 2, extended: false),
                       CGSize(width: 2752, height: 1786))
        XCTAssertEqual(ScreenCapture.frameSize(width: 3840, height: 2160, pointPixelScale: 1, extended: false),
                       CGSize(width: 2752, height: 1548))
        XCTAssertEqual(ScreenCapture.frameSize(width: 2160, height: 3840, pointPixelScale: 1, extended: false),
                       CGSize(width: 1548, height: 2752))
        XCTAssertEqual(ScreenCapture.frameSize(width: 1512, height: 982, pointPixelScale: 2, extended: false, detailed: false),
                       CGSize(width: 1846, height: 1200))
        XCTAssertEqual(ScreenCapture.frameSize(width: 1280, height: 720, pointPixelScale: 1, extended: false),
                       CGSize(width: 1280, height: 720))
        XCTAssertEqual(ScreenCapture.frameSize(width: 1600, height: 1200, pointPixelScale: 2, extended: true),
                       CGSize(width: 1600, height: 1200))
    }

    @MainActor func testAuthenticatedViewerStartsScreenAutomatically() async throws {
        let token = String(repeating: "d", count: 64)
        let host = NativeHost(token: token)
        let activated = expectation(description: "authenticated connection activates screen")
        host.onViewerConnected = { activated.fulfill() }
        try host.start()
        defer { host.stop() }
        let client = try NativePeer(connection: NWConnection(host: "127.0.0.1", port: 8765,
            using: pairedParameters(token: token)), token: token)
        client.start()
        await fulfillment(of: [activated], timeout: 5)
        client.close()
    }

    private func pixel(_ index: Int, width: Int = 640, height: Int = 480) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw ProtocolError.invalidPacket }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 0.92, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in stride(from: 20, to: height - 20, by: 18) {
            context.setFillColor(CGColor(gray: Double(row % 5) * 0.06, alpha: 1))
            context.fill(CGRect(x: 25, y: row, width: width * 2 / 3 + row % 37, height: 7))
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: (index * 7) % (width - 70), y: height / 2, width: 60, height: 60))
        return buffer
    }

    func testWindowNeverQueuesMoreThanTwoAndSkipsOldCapture() {
        var window = VideoWindow()
        XCTAssertTrue(window.reserve(1)); XCTAssertTrue(window.reserve(2))
        XCTAssertFalse(window.reserve(3)); XCTAssertFalse(window.canEncode)
        XCTAssertTrue(window.acknowledge(1)); XCTAssertFalse(window.acknowledge(1))
        XCTAssertTrue(window.reserve(8)); XCTAssertTrue(window.acknowledge(2))
        XCTAssertFalse(window.reserve(3)); XCTAssertFalse(window.acknowledge(99))
    }

    func testVideoPacketRejectsMalformedParameterSetsAndNALUnits() throws {
        let packet = EncodedVideoFrame(sequence: 1, sps: Data([0x67]), pps: Data([0x68]), avcc: Data([0, 0, 0, 2, 0x65, 0x88]))
        XCTAssertEqual(try EncodedVideoFrame(data: packet.data).sequence, 1)
        XCTAssertThrowsError(try EncodedVideoFrame(data: Data(repeating: 0, count: 30)))
        var broken = packet.data; broken[8] = 0xff
        XCTAssertThrowsError(try EncodedVideoFrame(data: broken))
        broken = packet.data; broken.removeLast()
        XCTAssertThrowsError(try EncodedVideoFrame(data: broken))
    }

    func testRealEncoderDecoderAndBandwidthAgainstJPEG() async throws {
        let encoder = H264Encoder(), decoder = H264Decoder(), jpegContext = CIContext()
        var jpegBytes = 0, videoBytes = 0, encodeSeconds: Double = 0
        for index in 0..<30 {
            let source = try pixel(index, width: 1600, height: 1200)
            let image = CIImage(cvPixelBuffer: source)
            let jpeg = try XCTUnwrap(jpegContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]))
            jpegBytes += jpeg.count
            let start = ProcessInfo.processInfo.systemUptime
            let encoded: EncodedVideoFrame = try await withCheckedThrowingContinuation { continuation in
                encoder.encode(source, sequence: UInt64(index + 1)) { continuation.resume(with: $0) }
            }
            encodeSeconds += ProcessInfo.processInfo.systemUptime - start
            let received = try EncodedVideoFrame(data: encoded.data)
            videoBytes += received.data.count
            let decoded: CVPixelBuffer = try await withCheckedThrowingContinuation { continuation in
                decoder.decode(received) { continuation.resume(with: $0) }
            }
            XCTAssertEqual(CVPixelBufferGetWidth(decoded), 1600)
            XCTAssertEqual(CVPixelBufferGetHeight(decoded), 1200)
        }
        XCTAssertLessThan(videoBytes, jpegBytes)
        print("VIDEO BENCH: 30 synthetic 1600x1200 frames; JPEG=\(jpegBytes) bytes; H264=\(videoBytes) bytes; mean encode=\(String(format: "%.2f", encodeSeconds / 30 * 1000))ms; hardware=\(encoder.usesHardware)")
    }

    @MainActor func testFreshVideoCrossesRealEncryptedTransportAndAcknowledges() async throws {
        let token = String(repeating: "c", count: 64)
        let ready = expectation(description: "video listener ready"), received = expectation(description: "freshest H264 frame rendered")
        let listener = try NWListener(using: pairedParameters(token: token), on: .any)
        let pixel = try pixel(0)
        var sender: VideoSender?, server: NativePeer?
        let decoder = H264Decoder()
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                server = try! NativePeer(connection: connection, token: token)
                server?.onReady = {
                    let video = VideoSender(peer: server!); sender = video
                    video.onFailure = { XCTFail($0) }
                    for sequence in 1...8 { video.offer(RawVideoFrame(sequence: UInt64(sequence), pixel: pixel)) }
                }
                server?.onPacket = { packet in
                    if packet.kind == .frameAck { sender?.acknowledge(packet.body.reduce(0) { ($0 << 8) | UInt64($1) }) }
                }
                server?.start()
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 3)
        let client = try NativePeer(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: pairedParameters(token: token)), token: token)
        client.onPacket = { packet in
            do {
                XCTAssertEqual(packet.kind, .videoFrame)
                let frame = try EncodedVideoFrame(data: packet.body)
                decoder.decode(frame) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let pixel):
                            XCTAssertEqual(CVPixelBufferGetWidth(pixel), 640)
                            var sequence = frame.sequence.bigEndian
                            client.send(Packet(.frameAck, withUnsafeBytes(of: &sequence) { Data($0) }))
                            if frame.sequence == 8 { received.fulfill() }
                        case .failure(let error): XCTFail(error.localizedDescription)
                        }
                    }
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        client.start()
        await fulfillment(of: [received], timeout: 8)
        sender?.stop(); client.close(); server?.close(); listener.cancel()
    }
}
