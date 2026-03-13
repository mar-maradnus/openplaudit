/// Tests for sessionFilename, formatLocalTime, and remediation messages.

import Foundation
import Testing
@testable import SyncEngine
import BLEKit

@Suite("sessionFilename")
struct SessionFilenameTests {
    @Test func knownTimestamp() {
        // 2025-01-15 11:56:40 UTC = 1736942200
        let result = sessionFilename(1736942200)
        #expect(result == "20250115_115640_UTC")
    }

    @Test func epoch() {
        let result = sessionFilename(0)
        #expect(result == "19700101_000000_UTC")
    }

    @Test func consistentAcrossRuns() {
        let a = sessionFilename(1700000000)
        let b = sessionFilename(1700000000)
        #expect(a == b)
    }

    @Test func differentTimestampsProduceDifferentNames() {
        let a = sessionFilename(1000)
        let b = sessionFilename(2000)
        #expect(a != b)
    }

    @Test func alwaysEndsWithUTC() {
        let result = sessionFilename(1600000000)
        #expect(result.hasSuffix("_UTC"))
    }
}

@Suite("formatLocalTime")
struct FormatLocalTimeTests {
    @Test func returnsNonEmptyString() {
        let result = formatLocalTime(1736942200)
        #expect(!result.isEmpty)
    }

    @Test func containsDateSeparator() {
        let result = formatLocalTime(1736942200)
        #expect(result.contains("-"))
        #expect(result.contains(":"))
    }
}

@Suite("BLE Remediation Messages")
struct RemediationTests {
    // We can't directly call SyncEngine.remediation(for:) since it's private.
    // Instead, test that BLEError descriptions are meaningful (the remediation
    // layer wraps these). These tests verify the error → message mapping.
    @Test func bluetoothOffDescription() {
        let err = BLEError.bluetoothOff
        #expect(err.localizedDescription.lowercased().contains("bluetooth"))
    }

    @Test func deviceNotFoundDescription() {
        let err = BLEError.deviceNotFound
        #expect(err.localizedDescription.lowercased().contains("not found"))
    }

    @Test func timeoutIncludesMessage() {
        let err = BLEError.timeout("waiting for handshake")
        #expect(err.localizedDescription.contains("waiting for handshake"))
    }

    @Test func transferRejectedIncludesStatus() {
        let err = BLEError.transferRejected(42)
        #expect(err.localizedDescription.contains("42"))
    }
}
