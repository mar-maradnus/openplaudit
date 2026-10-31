import Foundation

public enum PLAUDAIContainer {
    public static let magic = Data("PLAUD.AI".utf8)
    public static let headerSize = 512
    public static let nonceOffset = 0x84
    public static let segmentOffset = 0x90
    public static let keyCipherOffset = 0x100
    public static let keyCipherLength = 256
    public static let samplesPerFrame = 320   // 20 ms @ 16 kHz

    public enum ContainerError: Error, LocalizedError {
        case notAContainer
        case tooShort(Int)
        case badSegment(Int)
        case decryptionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAContainer: return "Not a PLAUD.AI recording (magic missing)"
            case .tooShort(let n): return "Recording too short: \(n) bytes"
            case .badSegment(let n): return "Implausible segment size: \(n)"
            case .decryptionFailed(let s): return "Decryption failed: \(s)"
            }
        }
    }

    public struct Header {
        public let nonce: Data
        public let segment: Int
        public let keyCipher: Data
        public let channel: Int
    }

    public static func isContainer(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8) == magic
    }

    public static func parseHeader(_ data: Data) throws -> Header {
        guard isContainer(data) else { throw ContainerError.notAContainer }
        guard data.count >= headerSize else { throw ContainerError.tooShort(data.count) }
        let segment = Int(readU32(data, at: segmentOffset))
        guard segment > 0, segment <= 4096 else { throw ContainerError.badSegment(segment) }
        return Header(
            nonce: data.subdata(in: nonceOffset..<(nonceOffset + 12)),
            segment: segment,
            keyCipher: data.subdata(in: keyCipherOffset..<(keyCipherOffset + keyCipherLength)),
            channel: Int(readU16(data, at: 0x32))
        )
    }

    public static func decryptToFrames(_ data: Data, privateKeyPEM: String) throws -> Data {
        let header = try parseHeader(data)
        let rsa = try RSAKey(pem: privateKeyPEM)
        let symmetric: Data
        do {
            symmetric = try rsa.decryptPKCS1(header.keyCipher)
        } catch {
            throw ContainerError.decryptionFailed(
                "RSA unwrap failed — this recording may predate the current device binding")
        }
        guard symmetric.count >= 32 else {
            throw ContainerError.decryptionFailed("symmetric key too short")
        }
        let key = symmetric.prefix(32)
        let cipher = ChaCha20(key: key, nonce: header.nonce)

        let audio = data.subdata(in: headerSize..<data.count)
        var out = Data(capacity: audio.count)
        var offset = 0
        while offset < audio.count {
            let end = min(offset + header.segment, audio.count)
            out.append(cipher.apply(audio.subdata(in: offset..<end)))
            offset = end
        }
        return out
    }

    static func readU16(_ d: Data, at i: Int) -> UInt16 {
        guard i + 1 < d.count else { return 0 }
        let b = [UInt8](d[i..<(i + 2)])
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    static func readU32(_ d: Data, at i: Int) -> UInt32 {
        guard i + 3 < d.count else { return 0 }
        let b = [UInt8](d[i..<(i + 4)])
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
}
