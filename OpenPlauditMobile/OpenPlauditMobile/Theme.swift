/// Unified design system — typography, colors, and shared components.
///
/// Typography: Apple's New York (system serif) condensed for headings,
/// SF Pro (system sans) for body. Mirrors Cormorant Garamond on the web.
/// Colors: Dark, warm palette with restrained accent use.

import SwiftUI

enum Theme {
    // MARK: - Colors

    static let background = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceElevated = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let border = Color.white.opacity(0.08)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.58)
    static let textTertiary = Color(white: 0.35)

    static let accent = Color(red: 0.90, green: 0.25, blue: 0.20)       // Record red
    static let accentSubtle = Color(red: 0.90, green: 0.25, blue: 0.20).opacity(0.15)

    static let statusSyncing = Color(red: 0.35, green: 0.58, blue: 0.96)
    static let statusTranscribed = Color(red: 0.30, green: 0.75, blue: 0.48)
    static let statusPending = Color(red: 0.85, green: 0.68, blue: 0.25)
    static let statusFailed = Color(red: 0.90, green: 0.30, blue: 0.25)

    // MARK: - Typography
    //
    // Headings use system serif (.serif = New York) with condensed width.
    // This gives a Garamond-like compressed feel native to Apple platforms.
    // Body uses the system default (SF Pro).

    /// Large display — timer, hero text.
    static let displayLarge = Font.system(size: 64, weight: .ultraLight, design: .serif)
    /// Section headings.
    static let displaySmall = Font.system(size: 28, weight: .light, design: .serif)
    /// Card titles, navigation.
    static let heading = Font.system(size: 20, weight: .regular, design: .serif)
    /// Section labels in transcript/detail views.
    static let title = Font.system(size: 17, weight: .medium, design: .serif)
    /// Row data — sans-serif, not a heading.
    static let rowTitle = Font.system(size: 17, weight: .medium, design: .default)

    /// Body text — system sans.
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    /// Secondary info.
    static let subhead = Font.system(size: 13, weight: .regular, design: .default)
    /// Badges, labels.
    static let caption = Font.system(size: 12, weight: .medium, design: .default)
    /// Timestamps, durations.
    static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
}

// MARK: - View Modifiers

/// Condensed width for serif headings.
struct CondensedSerif: ViewModifier {
    let font: Font
    func body(content: Content) -> some View {
        content
            .font(font)
            .fontWidth(.condensed)
    }
}

extension View {
    func serifHeading(_ font: Font = Theme.heading) -> some View {
        modifier(CondensedSerif(font: font))
    }
}

// MARK: - Reusable Components

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
            )
    }
}

struct StatusPill: View {
    let status: String

    var body: some View {
        Text(label)
            .font(Theme.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch status {
        case "recorded": return Theme.statusPending
        case "syncing": return Theme.statusSyncing
        case "synced": return Theme.statusSyncing
        case "transcribing": return Theme.statusSyncing
        case "transcribed": return Theme.statusTranscribed
        case "failed": return Theme.statusFailed
        default: return Theme.textTertiary
        }
    }

    private var label: String {
        switch status {
        case "recorded": return "Recorded"
        case "syncing": return "Syncing"
        case "synced": return "Synced"
        case "transcribing": return "Processing"
        case "transcribed": return "Transcribed"
        case "failed": return "Failed"
        default: return status.capitalized
        }
    }
}
