/// About window — project information, privacy rationale, firmware warning.

import AppKit
import SwiftUI
import SyncEngine

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenPlaudit")
                            .font(.title2.bold())
                        Text("Version 0.4.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Privacy rationale
                Text("Why this exists")
                    .font(.headline)

                Text("""
                    OpenPlaudit exists for people who prefer their recordings to remain \
                    local rather than uploaded to cloud services. The official PLAUD app \
                    uploads recordings to remote servers for processing. This tool keeps \
                    everything on your machine.
                    """)
                    .font(.body)

                Text("""
                    If cloud storage is not a concern for you, the official PLAUD app \
                    is better supported and less likely to break after firmware updates.
                    """)
                    .font(.body)
                    .foregroundStyle(.secondary)

                Divider()

                // Firmware warning
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Built on a reverse-engineered BLE protocol.")
                            .font(.callout.bold())
                        Text("Firmware updates to the PLAUD Note may break compatibility without warning.")
                            .font(.callout)
                        Text("OpenPlaudit is not affiliated with PLAUD Inc.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Divider()

                // Diagnostics
                HStack(spacing: 12) {
                    Button("Open Logs…") { openLogs() }
                        .accessibilityLabel("Open system logs for OpenPlaudit")
                    Button("Reveal Data Folder…") { revealDataFolder() }
                        .accessibilityLabel("Show OpenPlaudit data folder in Finder")
                }

                Spacer(minLength: 8)

                // Footer
                HStack {
                    Text("By Ram Sundaram")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("MIT License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("GitHub") {
                        if let url = URL(string: "https://github.com/mar-maradnus/openplaudit") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityLabel("Open project on GitHub")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 420, maxWidth: 420, minHeight: 420, maxHeight: 520)
    }

    private func openLogs() {
        // Open Console.app filtered to our subsystem
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }

    private func revealDataFolder() {
        let path = NSString(string: "~/.local/share/openplaudit").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        } else {
            // Create it first so Finder has something to show
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }
}
