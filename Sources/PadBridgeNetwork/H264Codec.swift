import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

private func codecError(_ status: OSStatus, _ operation: String) -> NSError {
    NSError(domain: "PadBridge.Video", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) gagal (\(status))."])
}

private final class EncodeRequest {
    let sequence: UInt64
    let completion: (Result<EncodedVideoFrame, Error>) -> Void
    init(_ sequence: UInt64, _ completion: @escaping (Result<EncodedVideoFrame, Error>) -> Void) {
        self.sequence = sequence; self.completion = completion
    }
}

#if os(macOS)
public final class H264Encoder {
    private let queue = DispatchQueue(label: "PadBridge.h264.encode", qos: .userInteractive)
    private let details: Bool
    private var session: VTCompressionSession?
    private var width = 0, height = 0
    public private(set) var usesHardware = false

    public init(details: Bool = true) { self.details = details }

    public func encode(_ pixel: CVPixelBuffer, sequence: UInt64, completion: @escaping (Result<EncodedVideoFrame, Error>) -> Void) {
        queue.async {
            do {
                let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
                if self.session == nil || self.width != width || self.height != height {
                    try self.configure(width: width, height: height)
                }
                let request = EncodeRequest(sequence, completion)
                let pointer = Unmanaged.passRetained(request).toOpaque()
                let result = VTCompressionSessionEncodeFrame(self.session!, imageBuffer: pixel,
                    presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30), duration: CMTime(value: 1, timescale: 30),
                    frameProperties: nil, sourceFrameRefcon: pointer, infoFlagsOut: nil)
                if result != noErr {
                    Unmanaged<EncodeRequest>.fromOpaque(pointer).release()
                    throw codecError(result, "Encode H.264")
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func configure(width: Int, height: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        let callback: VTCompressionOutputCallback = { _, reference, status, _, sample in
            guard let reference else { return }
            let request = Unmanaged<EncodeRequest>.fromOpaque(reference).takeRetainedValue()
            guard status == noErr, let sample, let format = sample.formatDescription, let block = sample.dataBuffer else {
                request.completion(.failure(codecError(status, "Output H.264"))); return
            }
            do {
                var sets = [Data]()
                for index in 0..<2 {
                    var bytes: UnsafePointer<UInt8>?, count = 0
                    let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &bytes, parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    guard result == noErr, let bytes, (1...4096).contains(count) else { throw codecError(result, "Parameter H.264") }
                    sets.append(Data(bytes: bytes, count: count))
                }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0, length < PacketDecoder.maximumLength - 8300 else { throw ProtocolError.invalidPacket }
                var data = Data(count: length)
                let result = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                guard result == noErr else { throw codecError(result, "Salin H.264") }
                request.completion(.success(EncodedVideoFrame(sequence: request.sequence, sps: sets[0], pps: sets[1], avcc: data)))
            } catch { request.completion(.failure(error)) }
        }
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        var result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback, refcon: nil, compressionSessionOut: &session)
        if result != noErr {
            specification.removeValue(forKey: kVTVideoEncoderSpecification_EnableLowLatencyRateControl)
            result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback, refcon: nil, compressionSessionOut: &session)
        }
        guard result == noErr, let session else { throw codecError(result, "Buat encoder H.264") }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!),
                             (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)] {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { throw codecError(status, "Konfigurasi encoder") }
        }
        let bitRate = details ? min(14_000_000, max(4_000_000, width * height * 5 / 2)) : 4_000_000
        result = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        guard result == noErr else { throw codecError(result, "Atur bitrate H.264") }
        for (key, value) in [(kVTCompressionPropertyKey_ExpectedFrameRate, 30),
                             (kVTCompressionPropertyKey_MaxKeyFrameInterval, 30),
                             (kVTCompressionPropertyKey_MaxFrameDelayCount, 1)] {
            VTSessionSetProperty(session, key: key, value: value as CFNumber)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        result = VTCompressionSessionPrepareToEncodeFrames(session)
        guard result == noErr else { throw codecError(result, "Siapkan encoder") }
        var hardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hardware)
        usesHardware = hardware?.takeRetainedValue() as? Bool ?? false
        self.width = width; self.height = height
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
#endif

private final class DecodeRequest {
    let completion: (Result<CVPixelBuffer, Error>) -> Void
    init(_ completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) { self.completion = completion }
}

public final class H264Decoder {
    private let queue = DispatchQueue(label: "PadBridge.h264.decode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data(), pps = Data()
    public init() {}

    public func decode(_ frame: EncodedVideoFrame, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        queue.async {
            do {
                if self.session == nil || self.sps != frame.sps || self.pps != frame.pps { try self.configure(frame) }
                var block: CMBlockBuffer?
                var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: frame.avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: frame.avcc.count, flags: 0, blockBufferOut: &block)
                guard status == noErr, let block else { throw codecError(status, "Buffer decode") }
                status = frame.avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.avcc.count) }
                guard status == noErr else { throw codecError(status, "Isi buffer decode") }
                var sample: CMSampleBuffer?
                var size = frame.avcc.count
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(frame.sequence), timescale: 30), decodeTimeStamp: .invalid)
                status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: self.format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
                guard status == noErr, let sample else { throw codecError(status, "Sample decode") }
                let request = Unmanaged.passRetained(DecodeRequest(completion)).toOpaque()
                status = VTDecompressionSessionDecodeFrame(self.session!, sampleBuffer: sample, flags: [], frameRefcon: request, infoFlagsOut: nil)
                if status != noErr { Unmanaged<DecodeRequest>.fromOpaque(request).release(); throw codecError(status, "Decode H.264") }
            } catch { completion(.failure(error)) }
        }
    }

    private func configure(_ frame: EncodedVideoFrame) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let status = frame.sps.withUnsafeBytes { sps in frame.pps.withUnsafeBytes { pps in
            let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [frame.sps.count, frame.pps.count]
            return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }}
        }}
        guard status == noErr, let format else { throw codecError(status, "Format H.264") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 4096, dimensions.height <= 4096 else { throw ProtocolError.invalidPacket }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, request, status, _, pixel, _, _ in
            guard let request else { return }
            let context = Unmanaged<DecodeRequest>.fromOpaque(request).takeRetainedValue()
            if status == noErr, let pixel { context.completion(.success(pixel)) }
            else { context.completion(.failure(codecError(status, "Output decode"))) }
        }, decompressionOutputRefCon: nil)
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &session)
        guard result == noErr, let session else { throw codecError(result, "Buat decoder") }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        sps = frame.sps; pps = frame.pps
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
