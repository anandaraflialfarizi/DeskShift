import Foundation

public struct EncodedVideoFrame {
    public let sequence: UInt64
    public let sps: Data
    public let pps: Data
    public let avcc: Data
    public init(sequence: UInt64, sps: Data, pps: Data, avcc: Data) {
        self.sequence = sequence; self.sps = sps; self.pps = pps; self.avcc = avcc
    }

    public var data: Data {
        var sequence = sequence.bigEndian
        var spsLength = UInt16(sps.count).bigEndian
        var ppsLength = UInt16(pps.count).bigEndian
        return withUnsafeBytes(of: &sequence) { Data($0) }
            + withUnsafeBytes(of: &spsLength) { Data($0) }
            + withUnsafeBytes(of: &ppsLength) { Data($0) } + sps + pps + avcc
    }

    public init(data: Data) throws {
        guard data.count > 16, data.count < PacketDecoder.maximumLength - 64 else { throw ProtocolError.invalidPacket }
        sequence = data.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
        let spsCount = data[8..<10].reduce(0) { ($0 << 8) | Int($1) }
        let ppsCount = data[10..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard sequence > 0, sequence <= UInt64(Int64.max), (1...4096).contains(spsCount),
              (1...4096).contains(ppsCount), 12 + spsCount + ppsCount + 4 < data.count else { throw ProtocolError.invalidPacket }
        sps = Data(data[12..<(12 + spsCount)])
        pps = Data(data[(12 + spsCount)..<(12 + spsCount + ppsCount)])
        avcc = Data(data.dropFirst(12 + spsCount + ppsCount))
        var offset = 0, units = 0
        while offset < avcc.count {
            guard avcc.count - offset >= 4 else { throw ProtocolError.invalidPacket }
            let length = avcc[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= avcc.count - offset - 4, units < 256 else { throw ProtocolError.invalidPacket }
            offset += 4 + length; units += 1
        }
    }
}

public struct VideoWindow {
    private var pending = Set<UInt64>()
    private var lastSequence: UInt64 = 0
    public init() {}
    public var canEncode: Bool { pending.count < 2 }
    public mutating func reserve(_ sequence: UInt64) -> Bool {
        guard canEncode, sequence > lastSequence else { return false }
        lastSequence = sequence; pending.insert(sequence); return true
    }
    public mutating func acknowledge(_ sequence: UInt64) -> Bool { pending.remove(sequence) != nil }
}
