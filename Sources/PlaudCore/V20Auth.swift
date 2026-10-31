import Foundation
import CryptoKit

public enum V20Auth {
    public static let cmdPreHandshakeNew: UInt16 = 0xFE20
    public static let cmdPreHandshakeConfirm: UInt16 = 0xFE11
    public static let cmdSendRSAPubKey: UInt16 = 0xFE12
    public static let cmdHandshake: UInt16 = 0x01
    public static let chunkSize = 100
    public static let mtuIndicator = Data([0x02, 0x00])

    public enum AuthError: Error, LocalizedError {
        case noConfirm
        case incompleteKeyMaterial(Int, Int)
        case keyMaterialTooShort(Int)
        case verificationFailed
        case handshakeRejected(UInt8)

        public var errorDescription: String? {
            switch self {
            case .noConfirm: return "Pre-handshake: device did not confirm"
            case .incompleteKeyMaterial(let got, let want):
                return "Pre-handshake: got \(got)/\(want) key-material chunks"
            case .keyMaterialTooShort(let n):
                return "Pre-handshake: key material too short (\(n) bytes)"
            case .verificationFailed:
                return "Pre-handshake: PLAUD.AI verification failed — wrong session keys"
            case .handshakeRejected(let s):
                return "Handshake rejected by device (status \(s))"
            }
        }
    }

    public static func preHandshakeChunk(cmd: UInt16, total: Int, index: Int,
                                         data: Data) -> Data {
        var out = Data()
        out.append(UInt8(cmd & 0xff)); out.append(UInt8((cmd >> 8) & 0xff))
        out.append(UInt8(total & 0xff)); out.append(UInt8(index & 0xff))
        out.append(data)
        return out
    }

    public static func buildCmd(_ cmd: UInt16, payload: Data = Data()) -> Data {
        var out = Data([0x01, UInt8(cmd & 0xff), UInt8((cmd >> 8) & 0xff)])
        out.append(payload)
        return out
    }

    public static func handshakePayload(token: String, portVersion: UInt8,
                                        ssn: String? = nil) -> Data {
        var p = mtuIndicator
        p.append(portVersion)
        var t = Data(token.utf8).prefix(32)
        while t.count < 32 { t.append(0) }
        p.append(t)
        if let ssn {
            var s = Data(ssn.utf8).prefix(8)
            while s.count < 8 { s.append(0) }
            p.append(s)
        }
        return p
    }

    public static func chunks(cmd: UInt16, data: Data, chunkSize: Int = chunkSize) -> [Data] {
        let total = max(1, (data.count + chunkSize - 1) / chunkSize)
        var out: [Data] = []
        out.reserveCapacity(total)
        for i in 0..<total {
            let start = i * chunkSize
            let end = min(start + chunkSize, data.count)
            let slice = start < data.count ? data.subdata(in: start..<end) : Data()
            out.append(preHandshakeChunk(cmd: cmd, total: total, index: i, data: slice))
        }
        return out
    }

    public struct SessionKeys {
        public let key: Data       // 32 bytes
        public let nonce: Data     // 12 bytes
        public let ad: Data        // 12 bytes
    }

    public static func sessionKeys(fromChunks frames: [Data],
                                   privateKeyPEM: String) throws -> SessionKeys {
        var expected: Int?
        var parts: [Int: Data] = [:]
        for f in frames {
            guard f.count >= 4 else { continue }
            guard UInt16(f[0]) | (UInt16(f[1]) << 8) == cmdSendRSAPubKey else { continue }
            let total = Int(f[2]), index = Int(f[3])
            if expected == nil { expected = total }
            guard total == expected else { continue }
            parts[index] = f.subdata(in: 4..<f.count)
        }
        let want = expected ?? 0
        guard want > 0, parts.count >= want else {
            throw AuthError.incompleteKeyMaterial(parts.count, want)
        }
        var blob = Data()
        for i in 0..<want { blob.append(parts[i] ?? Data()) }

        let rsa = try RSAKey(pem: privateKeyPEM)
        let dec = try rsa.decryptPKCS1(blob)
        guard dec.count >= 56 else { throw AuthError.keyMaterialTooShort(dec.count) }

        let keys = SessionKeys(
            key: dec.subdata(in: 0..<32),
            nonce: dec.subdata(in: 32..<44),
            ad: dec.subdata(in: 44..<56)
        )
        let sealedBlob = dec.subdata(in: 56..<dec.count)
        if sealedBlob.count > 16 {
            let ct = sealedBlob.subdata(in: 0..<(sealedBlob.count - 16))
            let tag = sealedBlob.subdata(in: (sealedBlob.count - 16)..<sealedBlob.count)
            if let plain = try? SessionCrypto.open(ciphertext: ct, tag: tag, keys: keys),
               let s = String(data: plain, encoding: .utf8), s.contains("PLAUD.AI") {
                return keys
            }
            throw AuthError.verificationFailed
        }
        return keys
    }
}

// Nonce is fixed for the session; counter increments before encrypting, so the first packet uses 2.
public final class SessionCrypto {
    public private(set) var sendCounter: UInt32 = 1
    public private(set) var receiveCounter: UInt32 = 0
    private let keys: V20Auth.SessionKeys

    public init(keys: V20Auth.SessionKeys) {
        self.keys = keys
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        sendCounter &+= 1
        var pt = Data()
        pt.append(UInt8(sendCounter & 0xff)); pt.append(UInt8((sendCounter >> 8) & 0xff))
        pt.append(UInt8((sendCounter >> 16) & 0xff)); pt.append(UInt8((sendCounter >> 24) & 0xff))
        pt.append(plaintext)
        let box = try ChaChaPoly.seal(pt, using: SymmetricKey(data: keys.key),
                                      nonce: try ChaChaPoly.Nonce(data: keys.nonce),
                                      authenticating: keys.ad)
        var out = Data(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public func decrypt(_ sealed: Data) throws -> Data {
        guard sealed.count > 16 else { return Data() }
        let ct = sealed.subdata(in: 0..<(sealed.count - 16))
        let tag = sealed.subdata(in: (sealed.count - 16)..<sealed.count)
        let plain = try SessionCrypto.open(ciphertext: ct, tag: tag, keys: keys)
        guard plain.count >= 4 else { return Data() }
        receiveCounter = UInt32(plain[0]) | (UInt32(plain[1]) << 8)
                       | (UInt32(plain[2]) << 16) | (UInt32(plain[3]) << 24)
        return plain.subdata(in: 4..<plain.count)
    }

    static func open(ciphertext: Data, tag: Data, keys: V20Auth.SessionKeys) throws -> Data {
        let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: keys.nonce),
                                           ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: keys.key),
                                   authenticating: keys.ad)
    }
}

public struct DeviceCredentials: Sendable {
    public let snSignature: Data
    public let rsaPublicKeyPEM: String
    public let rsaPrivateKeyPEM: String
    public let deviceToken: String?

    public enum ParseError: Error, LocalizedError {
        case missing(String)
        case badSignature
        public var errorDescription: String? {
            switch self {
            case .missing(let f): return "Credentials missing field: \(f)"
            case .badSignature: return "sn_signature is not valid base64"
            }
        }
    }

    public init(snSignature: Data, rsaPublicKeyPEM: String, rsaPrivateKeyPEM: String,
                deviceToken: String? = nil) {
        self.deviceToken = deviceToken
        self.snSignature = snSignature
        self.rsaPublicKeyPEM = rsaPublicKeyPEM
        self.rsaPrivateKeyPEM = rsaPrivateKeyPEM
    }

    public static func parse(markdown: String) throws -> DeviceCredentials {
        func field(_ name: String) throws -> String {
            let pattern = "\(name):\\s*(\\S+)"
            guard let r = try? NSRegularExpression(pattern: pattern) else {
                throw ParseError.missing(name)
            }
            let ns = markdown as NSString
            guard let m = r.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { throw ParseError.missing(name) }
            return ns.substring(with: m.range(at: 1))
        }
        func pem(_ name: String, kind: String) throws -> String {
            let pattern = "\(name):\\s*(-----BEGIN \(kind)-----.*?-----END \(kind)-----)"
            guard let r = try? NSRegularExpression(pattern: pattern,
                                                  options: [.dotMatchesLineSeparators]) else {
                throw ParseError.missing(name)
            }
            let ns = markdown as NSString
            guard let m = r.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { throw ParseError.missing(name) }
            return ns.substring(with: m.range(at: 1))
        }

        let sigB64 = try field("sn_signature")
        guard let sig = Data(base64Encoded: sigB64) else { throw ParseError.badSignature }
        return DeviceCredentials(
            snSignature: sig,
            rsaPublicKeyPEM: try pem("user_rsa_public_key", kind: "PUBLIC KEY"),
            rsaPrivateKeyPEM: try pem("user_rsa_private_key", kind: "PRIVATE KEY"),
            deviceToken: (try? field("device_token")).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    public var asMarkdown: String {
        """
        # PLAUD self-bind credentials (generated by bind.py)
        - sn_signature: \(snSignature.base64EncodedString())
        - user_rsa_public_key: \(rsaPublicKeyPEM)
        - user_rsa_private_key: \(rsaPrivateKeyPEM)
        """
    }
}
