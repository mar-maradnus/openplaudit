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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let tx = transcript {
                    // Summary section
                    if let summary = tx.summary {
                        Section {
                            Text(summary.content)
                                .font(.body)
                        } header: {
                            Label("Summary", systemImage: "doc.text")
                                .font(.headline)
                        }
                        .padding(.bottom, 8)

                        Divider()
                    }

                    // Mind map outline
                    if let mindmap = tx.mindmap, !mindmap.isEmpty {
                        Section {
                            Text(mindmap)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } header: {
                            Label("Mind Map", systemImage: "brain")
                                .font(.headline)
                        }
                        .padding(.bottom, 8)

                        Divider()
                    }

                    // Transcript segments
                    Section {
                        ForEach(Array(tx.segments.enumerated()), id: \.offset) { _, segment in
                            SegmentRow(segment: segment)
                        }
                    } header: {
                        Label("Transcript", systemImage: "text.quote")
                            .font(.headline)
                    }
                } else {
                    ContentUnavailableView("No Transcript",
                        systemImage: "text.badge.xmark",
                        description: Text("Transcript not yet available. Sync with your Mac to receive it."))
                }
            }
            .padding()
        }
        .navigationTitle(recording.filename)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SegmentRow: View {
    let segment: TranscriptionResult.Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }
                Text(formatTimestamp(segment.start))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
