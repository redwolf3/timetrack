#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// Reconcile panel — lets the user clear the two gates that block a submittable
// report:
//   Gate 1: ad-hoc capture tasks with time must be bound to a Known Task.
//   Gate 2: Known Tasks with bound time must not be provisional (need a real key).
//
// All state lives in AppState (reconcileUnbound, reconcileProvisional,
// reconcileKnownTasks, reconcileIsClean). This view only renders and calls
// the three AppState action methods: refreshReconcile, reconcileBind,
// reconcilePromote. No store calls, no date arithmetic, no Task{} blocks.
struct ReconcileView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Gate 1: tasks with time that haven't been bound to a Known Task.
                if !appState.reconcileUnbound.isEmpty {
                    sectionHeader("Unbound Tasks")
                    ForEach(appState.reconcileUnbound, id: \.task.id) { item in
                        UnboundRowView(item: item)
                    }
                }

                // Gate 2: Known Tasks that are still provisional (no real JIRA key)
                // but have time bound to them.
                if !appState.reconcileProvisional.isEmpty {
                    sectionHeader("Provisional Keys")
                    ForEach(appState.reconcileProvisional, id: \.id) { kt in
                        ProvisionalRowView(kt: kt)
                    }
                }

                // Clean state: both gates clear.
                if appState.reconcileIsClean {
                    Text("All time reconciled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear { appState.refreshReconcile() }
    }

    // Section header matching HistoryView's daySectionHeader padding/style.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - UnboundRowView

// One row per ad-hoc capture task that has time but no Known Task binding.
// @State var selectedKnownTask isolates Picker state per row — must live in a
// subview so SwiftUI creates a separate state instance per item identity.
private struct UnboundRowView: View {
    @EnvironmentObject var appState: AppState
    let item: Store.UnreconciledTask

    // nil means "nothing selected yet" (the placeholder option).
    @State private var selectedKnownTask: Int64? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.task.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(appState.formatDuration(item.totalSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.reconcileKnownTasks.isEmpty {
                // No Known Tasks exist yet — user must create one via CLI first.
                // Surfaced here so the panel doesn't look broken with an empty picker.
                Text("No known tasks — add one via CLI")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                // .menu style Picker + .small control size matches the compact
                // density of the rest of the popover (16pt horizontal, 3pt vertical).
                Picker("Bind to…", selection: $selectedKnownTask) {
                    Text("— select —").tag(Optional<Int64>.none)
                    ForEach(appState.reconcileKnownTasks, id: \.id) { kt in
                        // Provisional entries have no jiraKey; show description instead.
                        Text(kt.jiraKey ?? kt.description)
                            .tag(Optional(kt.id!))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                // Selection is the action — no separate confirm button.
                // Fast path for binding many tasks without extra taps.
                .onChange(of: selectedKnownTask) { _, newVal in
                    guard let ktid = newVal,
                          let tid = item.task.id else { return }
                    appState.reconcileBind(taskId: tid, knownTaskId: ktid)
                    // reconcileBind calls refreshReconcile which replaces reconcileUnbound,
                    // removing this row. The @State resets naturally as the row disappears.
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

// MARK: - ProvisionalRowView

// One row per Known Task that still has no real JIRA key but has time bound.
// @State var draftKey isolates text field state per row — separate subview for
// the same reason as UnboundRowView.
private struct ProvisionalRowView: View {
    @EnvironmentObject var appState: AppState
    let kt: KnownTask

    @State private var draftKey: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(kt.description)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            TextField("JIRA key…", text: $draftKey)
                .font(.caption)
                .frame(width: 80)
                .onSubmit { promote() }
            Button("Set", action: promote)
                .buttonStyle(.bordered)
                .controlSize(.small)
                // AppState also guards against empty/whitespace, but disable for UX
                // so the button is visually inert when the field is blank.
                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private func promote() {
        guard let id = kt.id else { return }
        appState.reconcilePromote(id: id, jiraKey: draftKey)
        // draftKey intentionally NOT cleared on success: if reconcilePromote no-ops
        // (guard triggers in AppState on whitespace), the field retains the bad
        // input so the user can correct it. On a valid promote, refreshReconcile
        // removes this row entirely, so the field reset is moot.
    }
}
#endif
