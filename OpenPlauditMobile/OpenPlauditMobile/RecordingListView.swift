/// Recording list — SwiftData-backed list with status badges and navigation.

import SwiftUI
import SwiftData

struct RecordingListView: View {
    @Query(sort: \RecordingModel.recordedAt, order: .reverse) private var recordings: [RecordingModel]

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView("No Recordings",
                        systemImage: "mic.slash",
                        description: Text("Tap Record to capture your first recording."))
                } else {
                    List {
                        ForEach(groupedByDate, id: \.key) { section in
                            Section(header: Text(section.key)) {
                                ForEach(section.recordings) { recording in
                                    NavigationLink(destination: destinationView(for: recording)) {
                                        RecordingRow(recording: recording)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
        }
    }

    @ViewBuilder
    private func destinationView(for recording: RecordingModel) -> some View {
        if recording.transcriptJSON != nil {
            TranscriptView(recording: recording)
        } else {
            RecordingDetailView(recording: recording)
        }
    }

    private var groupedByDate: [DateSection] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let grouped = Dictionary(grouping: recordings) { recording in
            formatter.string(from: recording.recordedAt)
        }

        return grouped.map { DateSection(key: $0.key, recordings: $0.value) }
            .sorted { $0.recordings[0].recordedAt > $1.recordings[0].recordedAt }
    }
}

private struct DateSection: Identifiable {
    let key: String
    let recordings: [RecordingModel]
    var id: String { key }
}

struct RecordingRow: View {
    let recording: RecordingModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeString)
                    .font(.headline)
                Text(durationString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(status: recording.status)
        }
        .padding(.vertical, 4)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: recording.recordedAt)
    }

    private var durationString: String {
        let total = Int(recording.durationSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%dm %02ds", minutes, seconds)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case "recorded": return .orange
        case "syncing": return .blue
        case "synced": return .blue
        case "transcribing": return .purple
        case "transcribed": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private var statusLabel: String {
        switch status {
        case "recorded": return "Recorded"
        case "syncing": return "Syncing…"
        case "synced": return "Synced"
        case "transcribing": return "Transcribing…"
        case "transcribed": return "Transcribed"
        case "failed": return "Failed"
        default: return status.capitalized
        }
    }
}

/// Simple detail view for recordings without transcripts.
struct RecordingDetailView: View {
    let recording: RecordingModel

    var body: some View {
        VStack(spacing: 16) {
            Text(recording.filename)
                .font(.headline)

            HStack(spacing: 24) {
                Label(durationString, systemImage: "clock")
                Label(sizeString, systemImage: "doc")
            }
            .foregroundStyle(.secondary)

            StatusBadge(status: recording.status)

            Spacer()
        }
        .padding()
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var durationString: String {
        let total = Int(recording.durationSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var sizeString: String {
        let mb = Double(recording.sizeBytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}
