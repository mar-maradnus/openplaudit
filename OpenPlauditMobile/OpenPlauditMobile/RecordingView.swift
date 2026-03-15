/// Main recording screen — one-tap record with waveform and timer.

import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var recorder = Recorder()
    @State private var selectedQuality: AudioQuality = .voice
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Timer
                Text(formattedDuration)
                    .serifHeading(Theme.displayLarge)
                    .foregroundStyle(recorder.isRecording ? Theme.textPrimary : Theme.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: recorder.durationSeconds)

                Spacer().frame(height: 12)

                // Status label
                Text(recorder.isRecording ? "Recording" : "Ready")
                    .font(Theme.subhead)
                    .foregroundStyle(recorder.isRecording ? Theme.accent : Theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(1.5)

                Spacer().frame(height: 48)

                // Waveform
                WaveformView(level: recorder.audioLevel, isRecording: recorder.isRecording)
                    .frame(height: 64)
                    .padding(.horizontal, 40)

                Spacer().frame(height: 56)

                // Record button
                Button(action: toggleRecording) {
                    ZStack {
                        // Outer ring
                        Circle()
                            .strokeBorder(
                                recorder.isRecording ? Theme.accent : Color.white.opacity(0.2),
                                lineWidth: 3
                            )
                            .frame(width: 88, height: 88)

                        // Pulsing glow when recording
                        if recorder.isRecording {
                            Circle()
                                .fill(Theme.accent.opacity(0.15))
                                .frame(width: 88, height: 88)
                        }

                        // Inner shape: circle → rounded square
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.accent)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 64, height: 64)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                .animation(.easeInOut(duration: 0.25), value: recorder.isRecording)

                Spacer().frame(height: 48)

                // Quality selector
                if !recorder.isRecording {
                    qualityPicker
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let error = errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.statusFailed)
                        .padding(.top, 12)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .animation(.easeInOut(duration: 0.3), value: recorder.isRecording)
    }

    // MARK: - Subviews

    private var qualityPicker: some View {
        HStack(spacing: 16) {
            ForEach(AudioQuality.allCases) { q in
                Button {
                    selectedQuality = q
                } label: {
                    VStack(spacing: 4) {
                        Text(q.rawValue)
                            .font(Theme.caption)
                            .foregroundStyle(selectedQuality == q ? Theme.textPrimary : Theme.textTertiary)
                        Text(q == .voice ? "16 kHz" : "48 kHz")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedQuality == q ? Theme.surfaceElevated : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        selectedQuality == q ? Theme.border : Color.clear,
                                        lineWidth: 0.5
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Formatting

    private var formattedDuration: String {
        let total = Int(recorder.durationSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Actions

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

// MARK: - Waveform

struct WaveformView: View {
    let level: Float
    let isRecording: Bool

    private let barCount = 28

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor(index: i))
                        .frame(
                            width: barWidth(geo: geo),
                            height: barHeight(index: i, totalHeight: geo.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barWidth(geo: GeometryProxy) -> CGFloat {
        let totalSpacing = CGFloat(barCount - 1) * 2.5
        return (geo.size.width - totalSpacing) / CGFloat(barCount)
    }

    private func barColor(index: Int) -> Color {
        guard isRecording else { return Theme.surfaceElevated }
        let centerDistance = abs(CGFloat(index) - CGFloat(barCount) / 2.0) / (CGFloat(barCount) / 2.0)
        return Theme.accent.opacity(0.4 + (1.0 - centerDistance) * 0.6 * Double(min(level * 6, 1.0)))
    }

    private func barHeight(index: Int, totalHeight: CGFloat) -> CGFloat {
        guard isRecording else { return 3 }
        let minH: CGFloat = 3
        let maxExtra = totalHeight - minH
        let phase = Double(index) * 0.35
        let wave = (sin(phase + Double(level) * 12) + 1) / 2
        let amplitude = CGFloat(min(level * 7, 1.0))
        return minH + maxExtra * CGFloat(wave) * amplitude
    }
}
