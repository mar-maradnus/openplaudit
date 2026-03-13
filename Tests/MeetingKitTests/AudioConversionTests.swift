/// Tests for Float32 → Int16 sample conversion.

import Foundation
import Testing
@testable import MeetingKit

@Suite("Float32 to Int16 conversion")
struct AudioConversionTests {

    @Test func zeroStaysZero() {
        #expect(float32ToInt16(0.0) == 0)
    }

    @Test func positiveFullScale() {
        #expect(float32ToInt16(1.0) == 32767)
    }

    @Test func negativeFullScale() {
        // -1.0 * 32767 = -32767 (not -32768 due to asymmetric Int16 range)
        #expect(float32ToInt16(-1.0) == -32767)
    }

    @Test func halfScale() {
        let result = float32ToInt16(0.5)
        #expect(result == 16383)  // Int16(0.5 * 32767)
    }

    @Test func negativeHalfScale() {
        let result = float32ToInt16(-0.5)
        #expect(result == -16383)
    }

    @Test func clampsAboveOne() {
        #expect(float32ToInt16(1.5) == 32767)
        #expect(float32ToInt16(100.0) == 32767)
    }

    @Test func clampsBelowNegativeOne() {
        #expect(float32ToInt16(-1.5) == -32767)
        #expect(float32ToInt16(-100.0) == -32767)
    }

    @Test func smallPositiveValue() {
        let result = float32ToInt16(0.001)
        #expect(result == 32)  // Int16(0.001 * 32767)
    }

    @Test func verySmallValueRoundsToZero() {
        let result = float32ToInt16(0.00001)
        #expect(result == 0)
    }
}
