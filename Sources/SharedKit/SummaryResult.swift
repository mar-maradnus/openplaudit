/// Summary result — cross-platform type shared between macOS and iOS.

import Foundation

/// Result of summarising a transcript.
public struct SummaryResult: Codable, Sendable, Equatable {
    public let template: String
    public let model: String
    public let content: String

    public init(template: String, model: String, content: String) {
        self.template = template
        self.model = model
        self.content = content
    }
}
