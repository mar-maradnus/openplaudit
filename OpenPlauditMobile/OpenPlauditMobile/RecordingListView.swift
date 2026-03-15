/// Recording list — SwiftData-backed list with status badges and navigation.

import SwiftUI
import SwiftData

struct RecordingListView: View {
    @Query(sort: \RecordingModel.recordedAt, order: .reverse) private var recordings: [RecordingModel]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if recordings.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(groupedByDate, id: \.key) { section in
                                sectionView(section)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("No recordings yet")
                .serifHeading(Theme.heading)
                .foregroundStyle(Theme.textSecondary)
            Text("Tap Record to capture your first recording.")
                .font(Theme.subhead)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Sections

    private func sectionView(_ section: DateSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.key)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.leading, 4)
                .padding(.top, 8)

            ForEach(section.recordings) { recording in
                NavigationLink(destination: destinationView(for: recording)) {
                    RecordingRow(recording: recording)
                }
                .buttonStyle(.plain)
            }
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

// MARK: - Row

struct RecordingRow: View {
    let recording: RecordingModel

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                // Time icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(timeString)
                        .serifHeading(Theme.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text(durationString)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                StatusPill(status: recording.status)
            }
        }
    }

    private var iconName: String {
        switch recording.status {
        case "transcribed": return "text.quote"
        case "syncing", "transcribing": return "arrow.triangle.2.circlepath"
        case "failed": return "exclamationmark.circle"
        default: return "waveform"
        }
    }

    private var iconColor: Color {
        switch recording.status {
        case "transcribed": return Theme.statusTranscribed
        case "syncing", "synced", "transcribing": return Theme.statusSyncing
        case "failed": return Theme.statusFailed
        default: return Theme.statusPending
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: recording.recordedAt)
    }

    private var durationString: String {
        let total = Int(recording.durationSeconds)
        if total >= 3600 {
            return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
        }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
}

// MARK: - Detail

struct RecordingDetailView: View {
    let recording: RecordingModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                // Icon
                ZStack {
                    Circle()
                        .fill(Theme.surface)
                        .frame(width: 72, height: 72)
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                }

                Text(recording.filename)
                    .serifHeading(Theme.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 24) {
                    Label(durationString, systemImage: "clock")
                    Label(sizeString, systemImage: "doc")
                }
                .font(Theme.subhead)
                .foregroundStyle(Theme.textSecondary)

                StatusPill(status: recording.status)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var durationString: String {
        let total = Int(recording.durationSeconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var sizeString: String {
        let mb = Double(recording.sizeBytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Supporting Types

private struct DateSection: Identifiable {
    let key: String
    let recordings: [RecordingModel]
    var id: String { key }
}
