/// Tests for MeetingDetector — app detection with injected running app list.

import Foundation
import Testing
@testable import MeetingKit

@Suite("MeetingDetector")
struct MeetingDetectorTests {

    // MARK: - Detection with monitored apps

    @Test func detectsMonitoredApp() {
        let detector = MeetingDetector {
            ["us.zoom.xos", "com.apple.Safari", "com.apple.Finder"]
        }
        let apps = detector.detect(
            monitoredApps: ["us.zoom.xos", "com.apple.FaceTime"],
            includeBrowsers: false
        )
        #expect(apps.count == 1)
        #expect(apps.first == .zoom)
    }

    @Test func ignoresUnmonitoredApp() {
        let detector = MeetingDetector {
            ["us.zoom.xos"]
        }
        let apps = detector.detect(
            monitoredApps: ["com.apple.FaceTime"],
            includeBrowsers: false
        )
        #expect(apps.isEmpty)
    }

    @Test func detectsMultipleApps() {
        let detector = MeetingDetector {
            ["us.zoom.xos", "com.apple.FaceTime", "com.apple.Finder"]
        }
        let apps = detector.detect(
            monitoredApps: ["us.zoom.xos", "com.apple.FaceTime"],
            includeBrowsers: false
        )
        #expect(apps.count == 2)
        let ids = Set(apps.map(\.rawValue))
        #expect(ids.contains("us.zoom.xos"))
        #expect(ids.contains("com.apple.FaceTime"))
    }

    @Test func returnsEmptyWhenNoMatch() {
        let detector = MeetingDetector {
            ["com.apple.Finder", "com.apple.TextEdit"]
        }
        let apps = detector.detect(
            monitoredApps: ["us.zoom.xos", "com.apple.FaceTime"],
            includeBrowsers: false
        )
        #expect(apps.isEmpty)
    }

    // MARK: - Browser filtering

    @Test func excludesBrowsersByDefault() {
        let detector = MeetingDetector {
            ["com.google.Chrome", "us.zoom.xos"]
        }
        let apps = detector.detect(
            monitoredApps: ["com.google.Chrome", "us.zoom.xos"],
            includeBrowsers: false
        )
        #expect(apps.count == 1)
        #expect(apps.first == .zoom)
    }

    @Test func includesBrowsersWhenEnabled() {
        let detector = MeetingDetector {
            ["com.google.Chrome", "us.zoom.xos"]
        }
        let apps = detector.detect(
            monitoredApps: ["com.google.Chrome", "us.zoom.xos"],
            includeBrowsers: true
        )
        #expect(apps.count == 2)
    }

    @Test func allBrowsersFilteredWhenDisabled() {
        let detector = MeetingDetector {
            ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"]
        }
        let apps = detector.detect(
            monitoredApps: MeetingApp.allCases.map(\.rawValue),
            includeBrowsers: false
        )
        #expect(apps.isEmpty)
    }

    @Test func allBrowsersIncludedWhenEnabled() {
        let detector = MeetingDetector {
            ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"]
        }
        let apps = detector.detect(
            monitoredApps: MeetingApp.allCases.map(\.rawValue),
            includeBrowsers: true
        )
        #expect(apps.count == 3)
    }

    // MARK: - MeetingApp properties

    @Test func meetingAppDisplayNames() {
        #expect(MeetingApp.zoom.displayName == "Zoom")
        #expect(MeetingApp.teamsNew.displayName == "Microsoft Teams")
        #expect(MeetingApp.facetime.displayName == "FaceTime")
    }

    @Test func browserDetection() {
        #expect(MeetingApp.chrome.isBrowser == true)
        #expect(MeetingApp.safari.isBrowser == true)
        #expect(MeetingApp.firefox.isBrowser == true)
        #expect(MeetingApp.zoom.isBrowser == false)
        #expect(MeetingApp.facetime.isBrowser == false)
    }
}
