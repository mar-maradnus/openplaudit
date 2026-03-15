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
    @State private var storageSize: String = "Calculating…"

    var body: some View {
        NavigationStack {
            Form {
                // Audio Quality
                Section {
                    Picker("Quality", selection: $audioQuality) {
                        ForEach(AudioQuality.allCases) { q in
                            Text(q.rawValue).tag(q.rawValue)
                        }
                    }
                } header: {
                    Text("Audio Quality")
                } footer: {
                    Text(currentQuality.description)
                }

                // Sync
                Section {
                    if pairedMacID.isEmpty {
                        TextField("6-digit code from Mac", text: $pairingCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)

                        Button("Pair with Mac") {
                            pairWithMac()
                        }
                        .disabled(pairingCode.count != 6 || isPairing)

                        if let error = pairingError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        LabeledContent("Paired Mac:", value: pairedMacName.isEmpty ? "Mac" : pairedMacName)

                        Toggle("Auto-sync", isOn: $autoSync)

                        Button("Unpair", role: .destructive) {
                            unpair()
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    if pairedMacID.isEmpty {
                        Text("Open Settings → Companion on your Mac to get a pairing code.")
                    }
                }

                // Storage
                Section {
                    LabeledContent("Local recordings:", value: storageSize)

                    Button("Clear Cache", role: .destructive) {
                        clearCache()
                    }
                } header: {
                    Text("Storage")
                }

                // About
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .onAppear { calculateStorageSize() }
        }
    }

    private var currentQuality: AudioQuality {
        AudioQuality(rawValue: audioQuality) ?? .voice
    }

    private func pairWithMac() {
        guard pairingCode.count == 6 else { return }
        isPairing = true
        pairingError = nil

        // Derive the pairing key from the code
        let key = derivePairingKey(from: pairingCode)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Store in UserDefaults for now (Keychain on iOS requires entitlements)
        UserDefaults.standard.set(keyData.base64EncodedString(), forKey: "pairingKey")
        pairedMacID = UUID().uuidString  // Will be updated on first connection
        pairedMacName = "Mac"

        isPairing = false
        pairingCode = ""
    }

    private func unpair() {
        pairedMacID = ""
        pairedMacName = ""
        UserDefaults.standard.removeObject(forKey: "pairingKey")
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
