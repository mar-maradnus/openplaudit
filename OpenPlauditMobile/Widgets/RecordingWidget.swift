/// Lock Screen widget for quick-start recording.

import WidgetKit
import SwiftUI
import AppIntents

struct RecordingWidget: Widget {
    let kind: String = "RecordingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordingTimelineProvider()) { entry in
            RecordingWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Record")
        .description("Tap to start recording with OpenPlaudit.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct RecordingEntry: TimelineEntry {
    let date: Date
}

struct RecordingTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingEntry {
        RecordingEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordingEntry) -> Void) {
        completion(RecordingEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingEntry>) -> Void) {
        let entry = RecordingEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct RecordingWidgetView: View {
    var entry: RecordingEntry

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.title2)
            .widgetURL(URL(string: "openplaudit://record"))
    }
}
