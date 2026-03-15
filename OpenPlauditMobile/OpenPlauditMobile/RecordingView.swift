/// Main recording screen — one-tap record with waveform and timer.

import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var recorder = Recorder()
    @State private var selectedQuality: AudioQuality = .voice
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Timer
                Text(formattedDuration)
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .monospacedDigit()

                // Waveform indicator
                WaveformView(level: recorder.audioLevel, isRecording: recorder.isRecording)
                    .frame(height: 60)
                    .padding(.horizontal, 32)

                // Record / Stop button
                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? .red : .red.opacity(0.85))
                            .frame(width: 80, height: 80)

                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(.white)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

                // Quality picker
                if !recorder.isRecording {
                    HStack {
                        Picker("Quality", selection: $selectedQuality) {
                            ForEach(AudioQuality.allCases) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)

                        Text(selectedQuality == .voice ? "16kHz" : "48kHz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var formattedDuration: String {
        let total = Int(recorder.durationSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        errorMessage = nil
        do {
            try recorder.start(quality: selectedQuality)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        do {
            let recording = try recorder.stop()
            // Save to SwiftData
            let model = RecordingModel(
                filename: recording.wavPath.lastPathComponent,
                durationSeconds: recording.durationSeconds,
                recordedAt: recording.startedAt,
                sizeBytes: recording.sizeBytes
            )
            modelContext.insert(model)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Simple waveform visualization based on audio level.
struct WaveformView: View {
    let level: Float
    let isRecording: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isRecording ? .red : .gray.opacity(0.3))
                        .frame(width: (geo.size.width - 57) / 20, height: barHeight(index: i, totalHeight: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barHeight(index: Int, totalHeight: CGFloat) -> CGFloat {
        guard isRecording else { return 4 }
        let base: CGFloat = 4
        let maxExtra = totalHeight - base
        // Create a wave pattern modulated by the audio level
        let phase = Double(index) * 0.3
        let wave = (sin(phase + Double(level) * 10) + 1) / 2
        let amplitude = CGFloat(min(level * 8, 1.0))
        return base + maxExtra * CGFloat(wave) * amplitude
    }
}
