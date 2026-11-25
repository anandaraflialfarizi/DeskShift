import XCTest
@preconcurrency import CoreVideo
import PadBridgeNetwork

final class DetailEncodingTests: XCTestCase {
    func testDetailedFrameRetainsFullSizeAndThinStrokes() async throws {
        let width = 2752, height = 1786
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        XCTAssertEqual(status, kCVReturnSuccess)
        let source = try XCTUnwrap(pixel)

        CVPixelBufferLockBaseAddress(source, [])
        let stride = CVPixelBufferGetBytesPerRow(source)
        let bytes = CVPixelBufferGetBaseAddress(source)!
        memset(bytes, 255, stride * height)
        for y in 256..<320 {
            let row = bytes.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in Swift.stride(from: 256, to: 384, by: 8) {
                row[x] = 0xFF10_1010
                row[x + 1] = 0xFF10_1010
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let encoder = H264Encoder(details: true), decoder = H264Decoder()
        let encoded: EncodedVideoFrame = try await withCheckedThrowingContinuation { continuation in
            encoder.encode(source, sequence: 1) { continuation.resume(with: $0) }
        }
        let received = try EncodedVideoFrame(data: encoded.data)
        let decoded: CVPixelBuffer = try await withCheckedThrowingContinuation { continuation in
            decoder.decode(received) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(CVPixelBufferGetWidth(decoded), width)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded), height)

        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(decoded)!
            .advanced(by: 288 * CVPixelBufferGetBytesPerRow(decoded)).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(Int(row[261 * 4]) - Int(row[257 * 4]), 64)
    }
}
