/// Menubar popup — status, sync button, recent recordings.

import SwiftUI
import SyncEngine

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

struct MenuBarView: View {
    @ObservedObject var engine: SyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status line
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            // Sync button
            Button(action: { Task { try? await engine.runSync() } }) {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)
            .padding(.horizontal)

            // Progress
            if let progress = engine.progress {
                ProgressView(value: progress.percentage, total: 100)
                    .padding(.horizontal)
                Text("\(Int(progress.percentage))% — \(progress.bytesReceived / 1024) KB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider()

            // Recent recordings
            if engine.recentRecordings.isEmpty {
                Text("No recent recordings")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(engine.recentRecordings) { recording in
                    HStack {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading) {
                            Text(recording.date, style: .date)
                                .font(.caption)
                            Text(recording.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let dur = recording.durationSeconds {
                            Text("\(Int(dur))s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            Divider()

            // Settings & Quit
            Button("Settings...") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .padding(.horizontal)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .frame(width: 260)
    }

    private var statusColor: Color {
        switch engine.status {
        case .idle: return engine.isConnected ? .green : .gray
        case .connecting: return .orange
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var statusText: String {
        switch engine.status {
        case .idle: return engine.isConnected ? "Connected" : "Idle"
        case .connecting: return "Connecting..."
        case .syncing(let current, let total): return "Syncing \(current)/\(total)..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var isSyncing: Bool {
        if case .syncing = engine.status { return true }
        if case .connecting = engine.status { return true }
        return false
    }
}
