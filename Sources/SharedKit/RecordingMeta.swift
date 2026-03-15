/// Recording metadata for manifest exchange between iPhone and Mac.

import Foundation

/// Recording metadata exchanged during sync.
public struct RecordingMeta: Codable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let durationSeconds: Double
    public let recordedAt: Date
    public let sizeBytes: Int
    public let status: RecordingStatus

    public init(id: String, filename: String, durationSeconds: Double, recordedAt: Date, sizeBytes: Int, status: RecordingStatus) {
        self.id = id
        self.filename = filename
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
        self.sizeBytes = sizeBytes
        self.status = status
    }
}

/// Status of a recording in the sync pipeline.
public enum RecordingStatus: String, Codable, Sendable {
    case recorded, syncing, synced, transcribing, transcribed, failed
}
