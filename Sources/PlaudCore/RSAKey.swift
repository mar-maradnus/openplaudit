import Foundation
import Security

public struct RSAKey {
    public enum KeyError: Error, LocalizedError {
        case badPEM
        case badDER
        case createFailed(CFError?)
        case decryptFailed(CFError?)

        public var errorDescription: String? {
            switch self {
            case .badPEM: return "Could not parse PEM private key"
            case .badDER: return "Could not parse DER private key"
            case .createFailed(let e): return "SecKeyCreateWithData failed: \(e.map { String(describing: $0) } ?? "unknown")"
            case .decryptFailed(let e): return "RSA decrypt failed: \(e.map { String(describing: $0) } ?? "unknown")"
            }
        }
    }

    private let key: SecKey

    public init(pem: String) throws {
        let der = try RSAKey.der(fromPEM: pem)
        let pkcs1 = RSAKey.pkcs1(fromPKCS8: der) ?? der
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw KeyError.createFailed(error?.takeRetainedValue())
        }
        self.key = k
    }

    public func decryptPKCS1(_ ciphertext: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            key, .rsaEncryptionPKCS1, ciphertext as CFData, &error
        ) else {
            throw KeyError.decryptFailed(error?.takeRetainedValue())
        }
        return plain as Data
    }

    static func der(fromPEM pem: String) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw KeyError.badPEM
        }
        return data
    }

    static func pkcs1(fromPKCS8 der: Data) -> Data? {
        let b = [UInt8](der)
        var i = 0

        func readTLV() -> (tag: UInt8, range: Range<Int>)? {
            guard i < b.count else { return nil }
            let tag = b[i]; i += 1
            guard i < b.count else { return nil }
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n > 0, n <= 4, i + n <= b.count else { return nil }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
            }
            guard i + len <= b.count else { return nil }
            let r = i..<(i + len); i += len
            return (tag, r)
        }

        guard let outer = readTLV(), outer.tag == 0x30 else { return nil }
        i = outer.range.lowerBound
        guard let _ = readTLV() else { return nil }
        guard let _ = readTLV() else { return nil }
        guard let octets = readTLV(), octets.tag == 0x04 else { return nil }
        return der.subdata(in: octets.range)
    }
}
