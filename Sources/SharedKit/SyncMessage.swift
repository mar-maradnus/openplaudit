/// Sync protocol message envelope for iPhone–Mac communication.
///
/// Each message is JSON-encoded and framed with a 4-byte little-endian length prefix
/// over TCP. See NetworkKit for framing and transport.

import Foundation

/// Current sync protocol version. Increment on breaking changes.
public let syncProtocolVersion: Int = 1

/// Sync protocol message envelope.
public enum SyncMessage: Codable, Sendable {
    case hello(deviceName: String, deviceID: String, protocolVersion: Int = syncProtocolVersion)
    case authChallenge(nonce: Data)
    case authResponse(hmac: Data)
    case recordingManifest([RecordingMeta])
    case uploadChunk(recordingID: String, offset: Int, data: Data)
    case uploadComplete(recordingID: String, sha256: String)
    case transcriptReady(recordingID: String, transcript: TranscriptionResult)
    case ack(messageID: String)
    case error(String)
}
