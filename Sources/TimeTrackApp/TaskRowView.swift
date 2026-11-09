#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// A single row in the task list. Bold + accent when this task is active.
// Tap calls select(taskId:), which delegates to tracker.switchTo() so the
// phase cycle is preserved on task switches (DESIGN.md: TRACKING → switch →
// TRACKING(task', same phase)).
//
// Two lines (#71): the JIRA key in a mono caption with today's time on the
// right, then the description wrapping to at most two lines. The key/description
// split comes from the kit (task.title) — this view never parses names.
//
// INVARIANT: every row has the same height, whatever its content. The popover
// sizes the task list as (row count × height of the first measured row), so a
// row that came out shorter or taller would break that arithmetic. Hence the
// description always reserves two lines, and a keyless row still draws a
// (blank) key line.
struct TaskRowView: View {
    let task: TimeTrackKit.Task
    @EnvironmentObject var appState: AppState

    @State private var isHovered: Bool = false

    private var isActive: Bool {
        guard let id = task.id else { return false }
        return appState.activeTaskId == id
    }

    private var title: TaskTitle { task.title }

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

    // What VoiceOver reads: "KDAL-1234, Paginate accounts API…, 25m". The blank
    // placeholder key line and the decorative indicator are left out.
    private var accessibilityText: String {
        [title.key, title.description, todayAnnotation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        Button {
            guard let id = task.id else { return }
            appState.select(taskId: id)
        } label: {
            // firstTextBaseline: the indicator sits on the key line, and SF
            // Symbol images carry a text baseline, so the dot lines up with it.
            HStack(alignment: .firstTextBaseline) {
                // Play/active indicator: the active row shows a filled dot so the
                // user always knows which task is running; inactive rows reveal a
                // play triangle on hover to signal "tap to switch here".
                // Fixed-width frame keeps the text column aligned across all rows.
                startIndicator
                    .frame(width: 16, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    keyLine

                    Text(title.description)
                        .font(isActive ? .body.bold() : .body)
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        // reservesSpace: a one-line description still occupies
                        // two lines, keeping every row the same height (see the
                        // invariant at the top of this file).
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        // The icons and the blank key placeholder are decorative; VoiceOver
        // reads key, description and today's time only. The active/tracked state
        // is conveyed via accessibilityValue so it remains perceivable without
        // the icon.
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityValue(isActive ? "Tracking" : "")
    }

    // Line 1: key (mono caption) on the left, today's time on the right.
    // A keyless task (an ad-hoc name with no JIRA key) renders a single space
    // in the same font, so the line keeps its height — see the file invariant.
    private var keyLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.key ?? " ")
                .font(.caption.monospaced())
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .lineLimit(1)

            Spacer()

            // Always present (a blank placeholder when there's no time today):
            // .caption and .caption.monospaced() have different line metrics,
            // so a conditionally-present annotation would make rows with and
            // without time today differ in height — see the file invariant.
            Text(todayAnnotation ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // The leading indicator column.
    // Active row: filled circle in accent colour — permanently visible, so the
    // running task is identifiable at a glance without hover.
    // Inactive row: play triangle is always in the hierarchy at opacity 0 at rest
    // and fades to 1 on hover. Keeping the same view identity (rather than
    // swapping Image / Color.clear) lets SwiftUI animate the opacity transition
    // smoothly instead of a hard swap. Layout width is identical in both states,
    // so task names stay flush across all rows.
    @ViewBuilder
    private var startIndicator: some View {
        if isActive {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)
                // Decorative: active state is conveyed by the button's accessibilityValue.
                .accessibilityHidden(true)
        } else {
            Image(systemName: "play.fill")
                .imageScale(.small)
                .foregroundStyle(Color.secondary)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                // Decorative: opacity-0 at rest; hiding prevents VoiceOver announcing
                // "Play" on every inactive row regardless of hover state.
                .accessibilityHidden(true)
        }
    }
}
#endif
