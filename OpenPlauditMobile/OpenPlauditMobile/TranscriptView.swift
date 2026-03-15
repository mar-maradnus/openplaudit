/// Read-only transcript viewer — displays synced transcription from Mac.
///
/// Shows speaker labels, timestamps, summary, and mind map outline.
/// No editing — this is a consumption view.

import SwiftUI
import SharedKit

struct TranscriptView: View {
    let recording: RecordingModel

    private var transcript: TranscriptionResult? {
        guard let data = recording.transcriptJSON else { return nil }
        return try? JSONDecoder().decode(TranscriptionResult.self, from: data)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let tx = transcript {
                        // Summary
                        if let summary = tx.summary {
                            transcriptSection("Summary", icon: "doc.text") {
                                Text(summary.content)
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineSpacing(4)
                            }
                        }

                        // Mind map
                        if let mindmap = tx.mindmap, !mindmap.isEmpty {
                            transcriptSection("Mind Map", icon: "brain") {
                                Text(mindmap)
                                    .font(Theme.mono)
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }

                        // Segments
                        transcriptSection("Transcript", icon: "text.quote") {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(tx.segments.enumerated()), id: \.offset) { _, segment in
                                    SegmentRow(segment: segment)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            Spacer().frame(height: 60)
                            Image(systemName: "text.badge.xmark")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(Theme.textTertiary)
                            Text("No transcript yet")
                                .serifHeading(Theme.heading)
                                .foregroundStyle(Theme.textSecondary)
                            Text("Sync with your Mac to receive the transcript.")
                                .font(Theme.subhead)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(recording.filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func transcriptSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .serifHeading(Theme.title)
                .foregroundStyle(Theme.textPrimary)

            content()

            Divider()
                .overlay(Theme.border)
                .padding(.top, 4)
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptionResult.Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(Theme.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.statusSyncing)
                }
                Text(formatTimestamp(segment.start))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(segment.text)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
