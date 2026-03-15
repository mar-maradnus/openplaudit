/// Sync protocol framing — length-prefixed JSON over TCP.
///
/// Wire format: [length:4LE][JSON payload]
/// Each frame is a JSON-encoded SyncMessage with a 4-byte little-endian length prefix.

import Foundation
import SharedKit

/// Encode a SyncMessage to a framed binary representation.
public func encodeFrame(_ message: SyncMessage) throws -> Data {
    let json = try JSONEncoder().encode(message)
    var length = UInt32(json.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(json)
    return frame
}

/// Decode a SyncMessage from a JSON payload (after the length prefix has been stripped).
public func decodeMessage(from json: Data) throws -> SyncMessage {
    try JSONDecoder().decode(SyncMessage.self, from: json)
}

/// Extract the frame length from the first 4 bytes (little-endian UInt32).
/// Returns nil if the data is too short.
public func frameLength(from data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    return data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
    }
}

/// Bonjour service type for OpenPlaudit companion sync.
public let syncServiceType = "_openplaudit._tcp"

/// Default chunk size for recording uploads (64KB).
public let uploadChunkSize = 64 * 1024
