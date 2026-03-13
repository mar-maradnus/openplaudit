/// Meeting app detection via NSWorkspace process monitoring.
///
/// Polls running applications against a configurable list of known meeting
/// app bundle identifiers. Browser detection is best-effort (browser running
/// does not imply a meeting is active).

import AppKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "meeting-detector")

/// Known meeting apps and their bundle identifiers.
public enum MeetingApp: String, CaseIterable, Sendable, Identifiable {
    case teamsNew       = "com.microsoft.teams2"
    case teamsClassic   = "com.microsoft.teams"
    case zoom           = "us.zoom.xos"
    case webex          = "com.cisco.webexmeetings"
    case slack          = "com.tinyspeck.slackmacgap"
    case facetime       = "com.apple.FaceTime"
    case chrome         = "com.google.Chrome"
    case safari         = "com.apple.Safari"
    case firefox        = "org.mozilla.firefox"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .teamsNew:     return "Microsoft Teams"
        case .teamsClassic: return "Microsoft Teams (Classic)"
        case .zoom:         return "Zoom"
        case .webex:        return "Webex"
        case .slack:        return "Slack"
        case .facetime:     return "FaceTime"
        case .chrome:       return "Chrome"
        case .safari:       return "Safari"
        case .firefox:      return "Firefox"
        }
    }

    public var isBrowser: Bool {
        switch self {
        case .chrome, .safari, .firefox: return true
        default: return false
        }
    }
}

/// Detects running meeting applications. Designed for dependency injection
/// in tests: pass a custom `runningAppProvider` to avoid hitting NSWorkspace.
public final class MeetingDetector: @unchecked Sendable {
    public typealias RunningAppProvider = @Sendable () -> [String]

    private let runningAppProvider: RunningAppProvider
    private var timer: Timer?
    private var previouslyDetected: Set<String> = []

    /// Callback fired when the set of detected meeting apps changes.
    /// `newApps` contains only apps that just appeared (were not in the previous poll).
    public var onChange: ((_ apps: [MeetingApp], _ newApps: Set<String>) -> Void)?

    /// Create a detector. In production, use the default provider (NSWorkspace).
    /// For tests, inject a closure returning known bundle IDs.
    public init(runningAppProvider: RunningAppProvider? = nil) {
        self.runningAppProvider = runningAppProvider ?? {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        }
    }

    /// Detect meeting apps running right now.
    public func detect(
        monitoredApps: [String],
        includeBrowsers: Bool
    ) -> [MeetingApp] {
        let runningBundleIDs = Set(runningAppProvider())
        return MeetingApp.allCases.filter { app in
            guard monitoredApps.contains(app.rawValue) else { return false }
            if app.isBrowser && !includeBrowsers { return false }
            return runningBundleIDs.contains(app.rawValue)
        }
    }

    /// Start polling every `interval` seconds. Fires `onChange` when apps change.
    @MainActor
    public func startMonitoring(
        monitoredApps: [String],
        includeBrowsers: Bool,
        interval: TimeInterval = 5.0
    ) {
        stopMonitoring()

        // Seed with current state so already-running apps aren't treated as "new".
        let initial = detect(monitoredApps: monitoredApps, includeBrowsers: includeBrowsers)
        previouslyDetected = Set(initial.map(\.rawValue))

        let tick = { [weak self] in
            guard let self else { return }
            let apps = self.detect(monitoredApps: monitoredApps, includeBrowsers: includeBrowsers)
            let current = Set(apps.map(\.rawValue))
            if current != self.previouslyDetected {
                let newApps = current.subtracting(self.previouslyDetected)
                self.previouslyDetected = current
                self.onChange?(apps, newApps)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
    }

    @MainActor
    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
