#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// Read-only convenience view of the last 7 calendar days of tracked time.
// All aggregation lives in Store.recentReport (the kit); this view only renders.
// Raw data is always accessible via `timetrack report` and the SQLite DB.
struct HistoryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(appState.history, id: \.day) { summary in
                    daySectionHeader(summary)
                    if summary.rows.isEmpty {
                        Text("No activity")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(summary.rows, id: \.task.id) { row in
                            taskRow(row)
                        }
                    }
                    Divider()
                }
            }
        }
        .onAppear { appState.refreshHistory() }
    }

    // Section header: "Today", "Yesterday", or weekday + short date + total.
    @ViewBuilder
    private func daySectionHeader(_ summary: Store.DaySummary) -> some View {
        HStack {
            Text(appState.dayLabel(for: summary.day))
                .font(.caption.bold())
                .foregroundStyle(.primary)
            Spacer()
            if summary.totalSeconds > 0 {
                Text(appState.formatDuration(summary.totalSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func taskRow(_ row: Store.DayRow) -> some View {
        // task.title (#71) splits the key off for display, so a legacy row whose
        // name embeds "KEY - description" shows split like a coded one. Display
        // only — stored names/codes are untouched. Key above description, same
        // order as the popover's task rows.
        let title = row.task.title
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                if let key = title.key {
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(title.description)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(appState.formatDuration(row.totalSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

}
#endif
