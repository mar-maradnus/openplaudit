/// Sync manager — wraps NetworkKit's SyncClient for the iOS app.
///
/// Manages Bonjour discovery, authentication, upload of new recordings,
/// and receipt of transcripts from the Mac.

import Foundation
import CryptoKit
import SwiftData
import NetworkKit
import SharedKit
import UIKit
import os

private let log = Logger(subsystem: "com.openplaudit.mobile", category: "sync")

@MainActor
final class SyncManager: ObservableObject, SyncClientDelegate {
    @Published var connectionState: SyncClientState = .disconnected
    private var client: SyncClient?
    private var modelContext: ModelContext?

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func startIfPaired() {
        guard let keyString = KeychainHelper.load(key: "pairingKey"),
              let keyData = Data(base64Encoded: keyString) else { return }

        let key = SymmetricKey(data: keyData)
        let deviceName = UIDevice.current.name
        let deviceID = UserDefaults.standard.string(forKey: "pairedMacID") ?? UUID().uuidString

        let client = SyncClient(pairingKey: key, deviceName: deviceName, deviceID: deviceID)
        client.delegate = self
        client.startBrowsing()
        self.client = client
    }

    func stop() {
        client?.stop()
        client = nil
    }

    func uploadPendingRecordings() {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<RecordingModel>(
            predicate: #Predicate { $0.status == "recorded" }
        )
        guard let pending = try? modelContext.fetch(descriptor), !pending.isEmpty else { return }

        let recordings: [(meta: RecordingMeta, wavData: Data)] = pending.compactMap { model in
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("recordings")
            let wavPath = documentsDir.appendingPathComponent(model.filename)
            guard let data = try? Data(contentsOf: wavPath) else { return nil }
            let meta = RecordingMeta(
                id: model.id,
                filename: model.filename,
                durationSeconds: model.durationSeconds,
                recordedAt: model.recordedAt,
                sizeBytes: model.sizeBytes,
                status: .recorded
            )
            model.status = RecordingStatus.syncing.rawValue
            return (meta: meta, wavData: data)
        }

        guard !recordings.isEmpty else { return }
        client?.uploadRecordings(recordings)
    }

    // MARK: - SyncClientDelegate

    nonisolated func syncClientStateDidChange(_ state: SyncClientState) {
        Task { @MainActor in
            self.connectionState = state
            if case .connected = state {
                self.uploadPendingRecordings()
            }
        }
    }

    nonisolated func syncClientDidReceiveTranscript(recordingID: String, transcript: TranscriptionResult) {
        Task { @MainActor in
            guard let modelContext = self.modelContext else { return }
            let descriptor = FetchDescriptor<RecordingModel>(
                predicate: #Predicate { $0.id == recordingID }
            )
            guard let model = try? modelContext.fetch(descriptor).first else {
                log.warning("Received transcript for unknown recording: \(recordingID)")
                return
            }
            model.transcriptJSON = try? JSONEncoder().encode(transcript)
            model.status = RecordingStatus.transcribed.rawValue
            log.info("Transcript received for \(recordingID)")
        }
    }

}
