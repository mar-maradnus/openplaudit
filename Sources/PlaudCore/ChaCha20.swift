import Foundation

public struct ChaCha20 {
    private let key: [UInt32]
    private let nonce: [UInt32]

    public init(key: Data, nonce: Data) {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")
        self.key = ChaCha20.words(key)
        self.nonce = ChaCha20.words(nonce)
    }

    public func apply(_ data: Data, counter: UInt32 = 0) -> Data {
        var out = Data(count: data.count)
        let bytes = [UInt8](data)
        var block = [UInt32](repeating: 0, count: 16)
        var ctr = counter
        var blockIndex = 0
        var blockBytes = [UInt8](repeating: 0, count: 64)

        out.withUnsafeMutableBytes { rawOut in
            guard let dst = rawOut.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<bytes.count {
                if i % 64 == 0 {
                    ChaCha20.block(key: key, nonce: nonce, counter: ctr, into: &block)
                    ChaCha20.serialize(block, into: &blockBytes)
                    ctr = ctr &+ 1
                    blockIndex = 0
                }
                dst[i] = bytes[i] ^ blockBytes[blockIndex]
                blockIndex += 1
            }
        }
        return out
    }

    private static func words(_ data: Data) -> [UInt32] {
        let b = [UInt8](data)
        var out = [UInt32]()
        out.reserveCapacity(b.count / 4)
        var i = 0
        while i + 3 < b.count {
            out.append(UInt32(b[i]) | (UInt32(b[i + 1]) << 8)
                       | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24))
            i += 4
        }
        return out
    }

    private static func block(key: [UInt32], nonce: [UInt32], counter: UInt32,
                              into out: inout [UInt32]) {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865; state[1] = 0x3320646e
        state[2] = 0x79622d32; state[3] = 0x6b206574
        for i in 0..<8 { state[4 + i] = key[i] }
        state[12] = counter
        for i in 0..<3 { state[13 + i] = nonce[i] }

        var x = state
        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = rotl(x[d], 16)
            x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = rotl(x[b], 12)
            x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = rotl(x[d], 8)
            x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = rotl(x[b], 7)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        for i in 0..<16 { out[i] = x[i] &+ state[i] }
    }

    private static func serialize(_ block: [UInt32], into out: inout [UInt8]) {
        for i in 0..<16 {
            let w = block[i]
            out[i * 4]     = UInt8(truncatingIfNeeded: w)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: w >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: w >> 16)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: w >> 24)
        }
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }
}
