/// Pairing key derivation and HMAC authentication.
///
/// One-time pairing via a 6-digit code derives a 256-bit shared key using
/// HKDF-SHA256. Subsequent connections authenticate via HMAC-SHA256
/// challenge-response.

import Foundation
import CryptoKit

/// Generate a random 6-digit pairing code.
public func generatePairingCode() -> String {
    let code = Int.random(in: 100_000...999_999)
    return String(code)
}

/// Derive a 256-bit symmetric key from a pairing code using HKDF-SHA256.
public func derivePairingKey(from code: String) -> SymmetricKey {
    let inputKey = SymmetricKey(data: Data(code.utf8))
    let salt = Data("openplaudit-pair".utf8)
    let info = Data("sync-key".utf8)
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey, salt: salt, info: info, outputByteCount: 32)
}

/// Generate a random 32-byte nonce for HMAC challenge.
public func generateNonce() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
    return Data(bytes)
}

/// Compute HMAC-SHA256 over data using the given key.
public func computeHMAC(data: Data, key: SymmetricKey) -> Data {
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
    return Data(mac)
}

/// Verify an HMAC-SHA256 response against expected data and key.
public func verifyHMAC(mac: Data, data: Data, key: SymmetricKey) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
}

/// Compute SHA256 hash of data, returned as a hex string.
public func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
