#if canImport(AppKit)
import SwiftUI
import TimeTrackKit

// Disambiguate Swift.Task concurrency from TimeTrackKit.Task data model.
private typealias AsyncTask = _Concurrency.Task

// Root popover content. ~280pt wide, up to ~400pt tall.
// Delegates all state reads to @EnvironmentObject AppState — no logic here.
struct MenuBarPopoverView: View {
    @EnvironmentObject var appState: AppState

    // Local state for the ad-hoc task text field.
    @State private var adHocName: String = ""
    @FocusState private var adHocFocused: Bool
    // Non-nil when addAndStart throws; cleared on next successful submit or edit.
    @State private var adHocError: String? = nil

    // Local state for the extend-minutes sheet.
    @State private var showExtendSheet: Bool = false
    @State private var extendMinutesText: String = ""
    @FocusState private var extendFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Status header ──────────────────────────────────────────────
            StatusHeaderView()

            Divider()

            // ── Armed actions (only when phase is armed) ───────────────────
            if !appState.armedActions.isEmpty {
                armedActionsSection
                Divider()
            }

            // ── Task list ──────────────────────────────────────────────────
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.tasks, id: \.id) { task in
                        TaskRowView(task: task)
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()

            // ── Ad-hoc task add row ────────────────────────────────────────
            adHocRow

            // ── Stop button (only when tracking or armed) ──────────────────
            if !appState.activeTaskName.isEmpty {
                Divider()
                stopRow
            }

            // ── Profile picker ────────────────────────────────────────────────
            Divider()
            profilePickerRow

            // ── Quit ──────────────────────────────────────────────────────────
            Divider()
            quitRow
        }
        .frame(width: 280)
        .background(.regularMaterial)
        .sheet(isPresented: $showExtendSheet) {
            extendSheet
        }
    }

    // MARK: - Armed actions

    @ViewBuilder
    private var armedActionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Use index as the ForEach identity. ArmAction labels are user-defined
            // YAML strings — using label as id risks duplicate-key rendering bugs
            // when two actions share the same label text.
            ForEach(Array(appState.armedActions.enumerated()), id: \.offset) { _, action in
                armedActionButton(action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func armedActionButton(_ action: ArmAction) -> some View {
        // Use action.label from the profile YAML verbatim — do not synthesize
        // button text here (that would ignore what the user configured).
        if action.advanceTo != nil {
            Button(action.label) {
                appState.advance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if let mins = action.extendMin {
            Button(action.label) {
                appState.extend(minutes: mins)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if action.extendPrompt == true {
            Button(action.label) {
                extendMinutesText = ""
                showExtendSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        // Actions with none of the three known kinds are silently ignored.
        // This matches the kit's own behavior: Profile decoding ignores unknown fields.
    }

    // MARK: - Ad-hoc task row

    private var adHocRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("New task…", text: $adHocName)
                    .textFieldStyle(.plain)
                    .focused($adHocFocused)
                    .onSubmit { submitAdHoc() }
                    // Clear the error as soon as the user edits the field.
                    .onChange(of: adHocName) { _, _ in adHocError = nil }

                if !adHocName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: submitAdHoc) {
                        Image(systemName: "return")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            // Surface task-creation errors so the user knows submission failed.
            // The text field retains its content so the entry is not lost.
            if let err = adHocError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submitAdHoc() {
        let name = adHocName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try appState.addAndStart(name: name)
            // Clear field only on success so the user sees their input on failure.
            adHocName = ""
            adHocError = nil
            adHocFocused = false
        } catch {
            // Keep adHocName intact; show a brief error message inline.
            adHocError = "Failed to create task: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop row

    private var stopRow: some View {
        HStack {
            Spacer()
            Button("Stop") {
                appState.stop()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.red)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Profile picker

    private var profilePickerRow: some View {
        HStack {
            Picker("Profile", selection: $appState.selectedProfileName) {
                ForEach(appState.profiles, id: \.name) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: appState.selectedProfileName) { _, name in
                appState.setProfile(name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Quit row

    private var quitRow: some View {
        HStack {
            Spacer()
            Button("Quit TimeTrack") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Extend sheet

    private var extendSheet: some View {
        VStack(spacing: 16) {
            Text("Extend phase by how many minutes?")
                .font(.headline)
            TextField("Minutes", text: $extendMinutesText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .focused($extendFocused)
                .onSubmit { submitExtend() }
            HStack(spacing: 12) {
                Button("Cancel") {
                    showExtendSheet = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Extend") {
                    submitExtend()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                // Require a positive integer — "0" parses but is rejected by submitExtend.
                .disabled((Int(extendMinutesText) ?? 0) <= 0)
            }
        }
        .padding(24)
        .frame(minWidth: 280)
        // Auto-focus the minutes field so the user can type immediately.
        .onAppear { extendFocused = true }
    }

    private func submitExtend() {
        guard let mins = Int(extendMinutesText), mins > 0 else { return }
        appState.extend(minutes: mins)
        showExtendSheet = false
    }
}
#endif
