import CoreGraphics
import CoreImage
import ImageIO
import Foundation

final class ScreenRenderer {
    private let decoder = H264Decoder()
    private let queue = DispatchQueue(label: "PadBridge.render", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var latestJPEG: (Data, (Result<CGImage, Error>) -> Void)?
    private var decodingJPEG = false

    func jpeg(_ data: Data, completion: @escaping (Result<CGImage, Error>) -> Void) {
        lock.lock()
        latestJPEG = (data, completion)
        let start = !decodingJPEG
        decodingJPEG = true
        lock.unlock()
        if start { queue.async { self.drainJPEG() } }
    }

    private func drainJPEG() {
        while true {
            lock.lock()
            let next = latestJPEG
            latestJPEG = nil
            if next == nil { decodingJPEG = false }
            lock.unlock()
            guard let (data, completion) = next else { return }
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...4096).contains(width), (1...4096).contains(height),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    completion(.failure(ProtocolError.invalidPacket)); return
                }
                completion(.success(image))
            }
        }
    }

    func h264(_ frame: EncodedVideoFrame, completion: @escaping (Result<CGImage, Error>) -> Void) {
        decoder.decode(frame) { result in
            self.queue.async {
                switch result {
                case .success(let pixel):
                    let image = CIImage(cvPixelBuffer: pixel)
                    if let cgImage = self.context.createCGImage(image, from: image.extent) { completion(.success(cgImage)) }
                    else { completion(.failure(ProtocolError.invalidPacket)) }
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }
}
