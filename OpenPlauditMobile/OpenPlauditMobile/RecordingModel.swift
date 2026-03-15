/// SwiftData model for local recording metadata.

import Foundation
import SwiftData

@Model
final class RecordingModel {
    var id: String
    var filename: String
    var durationSeconds: Double
    var recordedAt: Date
    var sizeBytes: Int
    var status: String  // RecordingStatus raw value
    var transcriptJSON: Data?  // Synced TranscriptionResult JSON from Mac

    init(id: String = UUID().uuidString, filename: String, durationSeconds: Double, recordedAt: Date = Date(), sizeBytes: Int, status: String = "recorded") {
        self.id = id
        self.filename = filename
        self.durationSeconds = durationSeconds
        self.recordedAt = recordedAt
        self.sizeBytes = sizeBytes
        self.status = status
    }
}
