/// Tests for BLE error classification — error descriptions and categorisation.

import Foundation
import Testing
@testable import BLEKit

@Suite("BLEError descriptions")
struct BLEErrorDescriptionTests {
    @Test func bluetoothOff() {
        let err = BLEError.bluetoothOff
        #expect(err.localizedDescription.contains("Bluetooth"))
        #expect(err.localizedDescription.contains("off"))
    }

    @Test func bluetoothUnauthorized() {
        let err = BLEError.bluetoothUnauthorized
        #expect(err.localizedDescription.contains("permission"))
    }

    @Test func deviceNotFound() {
        let err = BLEError.deviceNotFound
        #expect(err.localizedDescription.contains("not found"))
    }

    @Test func connectionFailedWithUnderlying() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "radio busy"])
        let err = BLEError.connectionFailed(underlying)
        #expect(err.localizedDescription.contains("radio busy"))
    }

    @Test func connectionFailedNil() {
        let err = BLEError.connectionFailed(nil)
        #expect(err.localizedDescription.contains("failed"))
    }

    @Test func disconnected() {
        let err = BLEError.disconnected
        #expect(err.localizedDescription.contains("disconnected"))
    }

    @Test func serviceNotFound() {
        let err = BLEError.serviceNotFound
        #expect(err.localizedDescription.contains("service"))
    }

    @Test func characteristicsNotFound() {
        let err = BLEError.characteristicsNotFound
        #expect(err.localizedDescription.contains("characteristics"))
    }

    @Test func notConnected() {
        let err = BLEError.notConnected
        #expect(err.localizedDescription.contains("Not connected"))
    }

    @Test func handshakeFailed() {
        let err = BLEError.handshakeFailed
        #expect(err.localizedDescription.contains("Handshake"))
    }

    @Test func timeoutIncludesContext() {
        let err = BLEError.timeout("waiting for sessions")
        #expect(err.localizedDescription.contains("waiting for sessions"))
    }

    @Test func transferRejectedIncludesStatus() {
        let err = BLEError.transferRejected(0x03)
        #expect(err.localizedDescription.contains("3"))
    }

    @Test func noResponseIncludesContext() {
        let err = BLEError.noResponse("handshake reply")
        #expect(err.localizedDescription.contains("handshake reply"))
    }
}

@Suite("BLEError is Error")
struct BLEErrorConformanceTests {
    @Test func allCasesAreErrors() {
        let cases: [any Error] = [
            BLEError.bluetoothOff,
            BLEError.bluetoothUnauthorized,
            BLEError.deviceNotFound,
            BLEError.connectionFailed(nil),
            BLEError.disconnected,
            BLEError.serviceNotFound,
            BLEError.characteristicsNotFound,
            BLEError.notConnected,
            BLEError.handshakeFailed,
            BLEError.timeout("test"),
            BLEError.transferRejected(1),
            BLEError.noResponse("test"),
        ]
        #expect(cases.count == 12)
        for err in cases {
            #expect(!err.localizedDescription.isEmpty)
        }
    }
}
