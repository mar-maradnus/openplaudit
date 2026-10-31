import Foundation

public enum TranscriptMarkdown {
    public static func render(_ result: Transcriber.Result, title: String,
                              created: Date = Date(), audioName: String? = nil,
                              sourceStem: String? = nil) -> String {
        let day = isoDay(created)
        var lines: [String] = []
        lines.append("---")
        var tags = ["plaud", "recording"]
        if result.chunksTranscribed > 1 { tags.append("long-recording") }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("created: \(day)")
        lines.append("updated: \(day)")
        lines.append("duration_seconds: \(Int(result.durationSeconds))")
        lines.append("duration: \(humanDuration(result.durationSeconds))")
        lines.append("model: \(result.model)")
        if result.chunksTranscribed > 1 {
            lines.append("chunks: \(result.chunksTranscribed)")
        }
        if let sourceStem { lines.append("source: \(sourceStem)") }
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")

        let opening = String(result.text.prefix(90))
        if !opening.isEmpty {
            lines.append("> \(opening)…")
            lines.append("")
        }

        var meta = ["**Duration:** \(humanDuration(result.durationSeconds))"]
        if result.chunksTranscribed > 1 {
            meta.append("**Chunks:** \(result.chunksTranscribed)")
        }
        meta.append("**Model:** \(result.model)")
        lines.append(meta.joined(separator: " · "))
        lines.append("")
        if let audioName {
            lines.append("**Audio:** `\(audioName)`")
            lines.append("")
        }

        for chunk in result.chunks where !chunk.text.isEmpty {
            lines.append("## \(clock(chunk.startSeconds)) – \(clock(chunk.endSeconds))")
            lines.append("")
            lines.append(chunk.text)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    public static func humanDuration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}
