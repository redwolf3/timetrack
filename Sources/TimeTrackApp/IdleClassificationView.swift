#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// Idle classification surface (#61).
//
// Non-modal by design: DESIGN.md §Escalation locks the ceiling at a persistent
// notification, NEVER a focus-steal modal. So this is an inline section of the
// menu-bar popover, placed near the top so it is visible without scrolling, and
// rendered only while segments are actually pending.
//
// Zero logic: every string AND every choice is precomputed in IdleSegmentItem —
// the view filters nothing and knows no task ids. The four buttons map 1:1 onto
// DESIGN.md's "keep on task / break / move to… / discard", expressed as
// IdleResolution cases; the kit turns each into exactly one idle_resolve over
// that segment's disjoint interval.
struct IdleClassificationView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Unclassified idle time")
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(appState.pendingIdleSegments) { item in
                IdleSegmentRowView(item: item)
            }
        }
    }
}

// One pending segment: a description line plus the four classification choices.
private struct IdleSegmentRowView: View {
    @EnvironmentObject var appState: AppState
    let item: IdleSegmentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(item.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text(item.timeRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.durationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("Keep on \(item.originalTaskName)") {
                    appState.resolveIdleSegment(item.id, as: .keepOnOriginal)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .lineLimit(1)
                .truncationMode(.tail)

                // Omitted when the choice is unhonourable (no break row in the
                // registry) or redundant (the segment already accrued to break,
                // so Keep and Break would do the same thing) — AppState owns both
                // conditions; see rebuildIdleSegmentItems.
                if item.offersBreak {
                    Button("Break") {
                        appState.resolveIdleSegment(item.id, as: .toBreak)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                // Omitted when there is nowhere else to move the time (the
                // single-task case, where the only task IS the original). An
                // always-present menu that opens empty reads as broken. Same
                // pattern as the Break button above; a row left with just Keep
                // and Discard is a complete, correct set of choices.
                if !item.moveTargets.isEmpty {
                    Menu("Move to") {
                        ForEach(item.moveTargets) { target in
                            Button(target.name) {
                                appState.resolveIdleSegment(item.id, as: .moveTo(taskId: target.id))
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }

                // Discard: the time is removed from the original task and credited
                // to nobody (idle_resolve with a null taskId).
                Button("Discard") {
                    appState.resolveIdleSegment(item.id, as: .discard)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif
