/// iOS settings — audio quality, sync status, pairing, storage management.

import SwiftUI
import CryptoKit
import NetworkKit
import SharedKit

struct SettingsView: View {
    @AppStorage("audioQuality") private var audioQuality: String = AudioQuality.voice.rawValue
    @AppStorage("pairedMacName") private var pairedMacName: String = ""
    @AppStorage("pairedMacID") private var pairedMacID: String = ""
    @AppStorage("autoSync") private var autoSync: Bool = true

    @State private var pairingCode: String = ""
    @State private var isPairing: Bool = false
    @State private var pairingError: String?
    @State private var storageSize: String = "Calculating..."

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Audio Quality
                        settingsSection("Audio Quality") {
                            qualityCard
                        }

                        // Sync
                        settingsSection("Sync") {
                            syncCard
                        }

                        // Storage
                        settingsSection("Storage") {
                            storageCard
                        }

                        // About
                        settingsSection("About") {
                            aboutCard
                        }

                        Spacer().frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { calculateStorageSize() }
        }
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.leading, 4)

            content()
        }
    }

    // MARK: - Cards

    private var qualityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(AudioQuality.allCases) { q in
                        Button {
                            audioQuality = q.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: q == .voice ? "mic" : "music.note")
                                    .font(.system(size: 18))
                                Text(q.rawValue)
                                    .font(Theme.caption)
                            }
                            .foregroundStyle(audioQuality == q.rawValue ? Theme.textPrimary : Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(audioQuality == q.rawValue ? Theme.surfaceElevated : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(currentQuality.description)
                    .font(Theme.subhead)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var syncCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                if pairedMacID.isEmpty {
                    TextField("6-digit code from Mac", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.surfaceElevated)
                        )

                    Button {
                        pairWithMac()
                    } label: {
                        Text("Pair with Mac")
                            .font(Theme.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(pairingCode.count == 6 ? Theme.accent : Theme.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(pairingCode.count != 6 || isPairing)

                    if let error = pairingError {
                        Text(error)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.statusFailed)
                    }

                    Text("Open Settings \u{2192} Companion on your Mac to get a pairing code.")
                        .font(Theme.subhead)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    HStack {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(Theme.statusTranscribed)
                        Text(pairedMacName.isEmpty ? "Mac" : pairedMacName)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        StatusPill(status: "synced")
                    }

                    Toggle(isOn: $autoSync) {
                        Text("Auto-sync")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.accent)

                    Button(role: .destructive) {
                        unpair()
                    } label: {
                        Text("Unpair")
                            .font(Theme.body)
                            .foregroundStyle(Theme.statusFailed)
                    }
                }
            }
        }
    }

    private var storageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Local recordings")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(storageSize)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textPrimary)
                }

                Button(role: .destructive) {
                    clearCache()
                } label: {
                    Text("Clear Cache")
                        .font(Theme.body)
                        .foregroundStyle(Theme.statusFailed)
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            HStack {
                Text("Version")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    // MARK: - Logic

    private var currentQuality: AudioQuality {
        AudioQuality(rawValue: audioQuality) ?? .voice
    }

    private func pairWithMac() {
        guard pairingCode.count == 6 else { return }
        isPairing = true
        pairingError = nil

        let key = derivePairingKey(from: pairingCode)
        let keyData = key.withUnsafeBytes { Data($0) }
        try? KeychainHelper.save(key: "pairingKey", value: keyData.base64EncodedString())
        pairedMacID = UUID().uuidString
        pairedMacName = "Mac"

        isPairing = false
        pairingCode = ""
    }

    private func unpair() {
        pairedMacID = ""
        pairedMacName = ""
        try? KeychainHelper.delete(key: "pairingKey")
    }

    private func calculateStorageSize() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: documentsDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            storageSize = "0 MB"
            return
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        let mb = Double(total) / 1_048_576.0
        storageSize = String(format: "%.1f MB", mb)
    }

    private func clearCache() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
        try? FileManager.default.removeItem(at: documentsDir)
        calculateStorageSize()
    }
}
