#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// A single row in the task list. Bold + accent when this task is active.
// Tap calls select(taskId:), which delegates to tracker.switchTo() so the
// phase cycle is preserved on task switches (DESIGN.md: TRACKING → switch →
// TRACKING(task', same phase)).
struct TaskRowView: View {
    let task: TimeTrackKit.Task
    @EnvironmentObject var appState: AppState

    @State private var isHovered: Bool = false

    private var isActive: Bool {
        guard let id = task.id else { return false }
        return appState.activeTaskId == id
    }

    // Format today's seconds for this task as a compact annotation.
    // Sub-minute time (1–59 s) is shown as "<1m" so the user knows time accrued
    // rather than seeing nothing or a misleading "0m".
    private var todayAnnotation: String? {
        guard let id = task.id, let secs = appState.todaySeconds[id], secs > 0 else {
            return nil
        }
        let m = secs / 60
        let h = m / 60
        if h > 0 {
            return "\(h)h \(m % 60)m"
        } else if m > 0 {
            return "\(m)m"
        } else {
            return "<1m"
        }
    }

    var body: some View {
        Button {
            guard let id = task.id else { return }
            appState.select(taskId: id)
        } label: {
            HStack {
                // Play/active indicator: the active row shows a filled dot so the
                // user always knows which task is running; inactive rows reveal a
                // play triangle on hover to signal "tap to switch here".
                // Fixed-width frame keeps the task name aligned across all rows.
                startIndicator
                    .frame(width: 16, alignment: .center)

                Text(task.name)
                    .font(isActive ? .body.bold() : .body)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let annotation = todayAnnotation {
                    Text(annotation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Subtle hover highlight so the pointer target is visible in the list.
            .background(isHovered && !isActive ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // Clear hover highlight when this row becomes active so isHovered does
        // not linger as stale true while the active background takes over.
        .onChange(of: isActive) { _, active in
            if active { isHovered = false }
        }
    }

    // The leading indicator column.
    // Active row: filled circle in accent colour — permanently visible, so the
    // running task is identifiable at a glance without hover.
    // Inactive row: play triangle appears on hover, fades away at rest, keeping
    // the list visually quiet while remaining discoverable as interactive.
    @ViewBuilder
    private var startIndicator: some View {
        if isActive {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)
        } else if isHovered {
            Image(systemName: "play.fill")
                .imageScale(.small)
                .foregroundStyle(Color.secondary)
        } else {
            // Reserve space so task names stay flush across all rows.
            Color.clear
        }
    }
}
#endif
