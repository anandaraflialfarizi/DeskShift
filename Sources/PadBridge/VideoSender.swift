import Foundation
import PadBridgeNetwork

final class VideoSender {
    private let peer: NativePeer
    private let encoder: H264Encoder
    private var window = VideoWindow()
    private var latest: RawVideoFrame?
    private var lastSequence: UInt64 = 0
    private var encoding = false
    private var stopped = false
    private var pending = [UInt64: Date]()
    var onFailure: ((String) -> Void)?
    init(peer: NativePeer, detailed: Bool = true) {
        self.peer = peer
        encoder = H264Encoder(details: detailed)
    }

    func offer(_ frame: RawVideoFrame) { latest = frame; pump() }
    func acknowledge(_ sequence: UInt64) {
        guard window.acknowledge(sequence) else { return }
        pending.removeValue(forKey: sequence); pump()
    }
    func checkTimeout() {
        if pending.values.contains(where: { Date().timeIntervalSince($0) > 5 }) { fail("Video terlalu lama menunggu iPad; beralih ke JPEG.") }
    }
    func stop() { stopped = true; latest = nil }
    func discardLatest() { latest = nil }
    private func pump() {
        guard !stopped, !encoding, window.canEncode, let frame = latest,
              frame.sequence > lastSequence, window.reserve(frame.sequence) else { return }
        lastSequence = frame.sequence; encoding = true; pending[frame.sequence] = Date()
        encoder.encode(frame.pixel, sequence: frame.sequence) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.encoding = false
                switch result {
                case .success(let frame):
                    guard self.peer.send(Packet(.videoFrame, frame.data)) else {
                        self.peer.close("Koneksi tidak dapat mengikuti aliran video."); self.stop(); return
                    }
                    self.pump()
                case .failure(let error): self.fail("H.264 tidak tersedia, memakai JPEG. \(error.localizedDescription)")
                }
            }
        }
    }
    private func fail(_ message: String) { guard !stopped else { return }; stop(); onFailure?(message) }
}
