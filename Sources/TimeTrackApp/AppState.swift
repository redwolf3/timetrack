#if canImport(AppKit)
import SwiftUI
import TimeTrackKit
import UserNotifications

// Disambiguate Swift.Task (concurrency) from TimeTrackKit.Task (the data model).
// Within this file, `AsyncTask` refers to Swift's concurrency primitive.
private typealias AsyncTask<S, F: Error> = _Concurrency.Task<S, F>

enum AppStateError: Error {
    case taskNotFoundAfterInsert(name: String)
}

// Single @MainActor ObservableObject that mediates between TimeTrackKit and
// all views. Views read @Published properties and call public methods; they
// contain zero conditional logic about tracker state. All TrackerState
// pattern-matching is funneled through updatePublished(from:) — that is the
// ONLY place in the app layer where TrackerState cases are inspected.
@MainActor
final class AppState: ObservableObject {

    // MARK: - @Published properties (read by views)

    // Menu-bar icon
    @Published var iconSymbol: String = "timer"
    @Published var iconColor: Color = .secondary

    // Status bar (top of popover)
    @Published var activeTaskName: String = ""
    @Published var phaseLabel: String = ""
    @Published var elapsedSeconds: Int = 0
    @Published var trackerState: TrackerState = .idle

    // Task list
    @Published var tasks: [Task] = []
    @Published var activeTaskId: Int64? = nil

    // Armed boundary actions — non-empty only when state == .armed
    @Published var armedActions: [ArmAction] = []

    // Profiles
    @Published var profiles: [Profile] = []
    @Published var selectedProfileName: String = "default"

    // Today totals (taskId -> seconds) for row annotations
    @Published var todaySeconds: [Int64: Int] = [:]

    // isActive is derived once in updatePublished and read by the elapsed timer.
    // This lets startElapsedTimer avoid inspecting TrackerState directly, keeping
    // updatePublished the ONLY TrackerState inspection site in the app layer.
    private var isActive: Bool = false

    // MARK: - Internals

    private let store: Store
    private let tracker: Tracker

    // App-support data directory (single source from App.dataDirectory()).
    // Held so the Config menu actions can reveal it / open the YAML files
    // without re-deriving the path — invariant: no path duplicated (#18).
    private let dataDir: URL

    // Background async tasks holding the stream subscriptions.
    // nonisolated(unsafe): deinit is nonisolated (SE-0371/Swift 5.10); we need
    // to cancel all three tasks from deinit without actor isolation.
    nonisolated(unsafe) private var stateTask: AsyncTask<Void, Never>?
    nonisolated(unsafe) private var effectTask: AsyncTask<Void, Never>?
    nonisolated(unsafe) private var elapsedTask: AsyncTask<Void, Never>?

    // Tracks the Date when the current phase/task started so elapsedSeconds
    // can be computed without querying the DB every second.
    private var phaseStart: Date = Date()

    // MARK: - Init

    init(store: Store, profilesURL: URL, dataDir: URL) throws {
        self.store = store
        self.dataDir = dataDir
        self.tracker = try Tracker(store: store, profilesURL: profilesURL, idleSource: SystemIdleSource())
        self.profiles = tracker.profiles
        self.tasks = try store.userTasks()
        updatePublished(from: tracker.state)
        subscribeToStateStream()
        subscribeToEffectStream()
        startElapsedTimer()
        requestNotificationAuthorization()
    }

    // Request UNUserNotificationCenter authorization for escalation ceiling
    // notifications (DESIGN.md: persistent notification, never a modal). Called
    // once at init; UNUserNotificationCenter de-duplicates subsequent requests.
    // Only prompts when authorization is .notDetermined — denied users are not
    // re-prompted. Must be nonisolated so it can fire a detached Task without
    // capturing the @MainActor-isolated self.
    private func requestNotificationAuthorization() {
        // UNUserNotificationCenter requires a bundle ID — unavailable in unbundled
        // binaries produced by `swift build`. Skip silently; Xcode builds have a bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Use _Concurrency.Task to avoid conflict with TimeTrackKit.Task.
        _Concurrency.Task.detached {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            try? await center.requestAuthorization(options: [.alert])
        }
    }

    // MARK: - deinit

    // Cancel all three background tasks so stream loops exit promptly.
    // nonisolated: deinit is always nonisolated (SE-0371). Task.cancel() is
    // itself nonisolated, so this is safe. The task handles are
    // nonisolated(unsafe) above — deinit only runs after all strong refs are
    // gone, so there is no concurrent actor access.
    nonisolated func cleanup() {
        stateTask?.cancel()
        effectTask?.cancel()
        elapsedTask?.cancel()
    }

    deinit {
        cleanup()
    }

    // MARK: - Stream subscriptions

    // RETAIN-CYCLE NOTE: do NOT use `guard let self` BEFORE the for-await loop.
    // A guard-let before the loop promotes the weak capture to a strong local
    // reference that persists for the entire suspension (the whole loop body),
    // creating the very cycle: AppState → stateTask/effectTask (nonisolated Task
    // handle) → Task closure body → strong `self` → AppState. Instead, we capture
    // `tracker` directly (not through self) and re-check `self` weakly on each
    // iteration inside MainActor.run, so when the last external strong reference
    // drops the next iteration finds self == nil and the loop exits naturally,
    // allowing deinit (and cleanup()) to fire without deadlocking.
    private func subscribeToStateStream() {
        let tracker = self.tracker   // capture tracker directly, not through self
        stateTask = AsyncTask { [weak self] in
            for await state in await tracker.stateStream {
                guard let self else { return }  // per-iteration weak check
                await MainActor.run { [weak self] in
                    self?.updatePublished(from: state)
                }
            }
        }
    }

    // Exhaustive switch — no default. Adding a case to Effect (e.g. .postNotification)
    // will produce a compile error here intentionally, forcing explicit wiring.
    private func subscribeToEffectStream() {
        let tracker = self.tracker   // capture tracker directly, not through self
        effectTask = AsyncTask { [weak self] in
            for await effect in await tracker.effectStream {
                guard let self else { return }  // per-iteration weak check
                switch effect {
                case .playSound(let name):
                    Sounds.play(name)
                case .postNotification(let title, let body):
                    await self.postNotification(title: title, body: body)
                }
            }
        }
    }

    // Posts a system notification. Called from the effect stream when an
    // escalation rung has notify: true. Per DESIGN.md, the ceiling is a
    // persistent notification, never a focus-steal modal.
    @MainActor
    private func postNotification(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil   // escalation rungs already play sound via .playSound
        let req = UNNotificationRequest(
            identifier: "timetrack.idle.escalation",
            content: content,
            trigger: nil)  // deliver immediately; replacing same id updates the existing one
        try? await center.add(req)
    }

    // 1 Hz loop that increments elapsedSeconds when tracking or armed.
    // Reads `isActive` (set by updatePublished) instead of pattern-matching
    // TrackerState directly — this keeps updatePublished the single chokepoint
    // for all TrackerState inspection in the app layer.
    private func startElapsedTimer() {
        elapsedTask = AsyncTask { [weak self] in
            while true {
                // sleep(nanoseconds:) throws CancellationError when cancelled.
                do { try await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self else { return }
                await MainActor.run {
                    if self.isActive {
                        self.elapsedSeconds = Int(Date().timeIntervalSince(self.phaseStart))
                    } else {
                        self.elapsedSeconds = 0
                    }
                    // Keep per-task time annotations live at 1 Hz.
                    // tracker.todaySeconds is already refreshed every second by the
                    // tick loop; copying it here avoids a separate DB query and ensures
                    // task rows show current totals throughout a phase, not just at
                    // state transitions.
                    self.todaySeconds = self.tracker.todaySeconds
                }
            }
        }
    }

    // MARK: - updatePublished — SINGLE chokepoint for TrackerState

    // This is the ONLY place in the entire app that pattern-matches TrackerState.
    // All @Published properties are derived here from the canonical state value.
    // isActive is also set here so startElapsedTimer never needs to inspect state.
    private func updatePublished(from state: TrackerState) {
        trackerState = state
        todaySeconds = tracker.todaySeconds

        switch state {
        case .idle:
            isActive = false
            iconSymbol = "timer"
            iconColor = .secondary
            activeTaskName = ""
            phaseLabel = ""
            elapsedSeconds = 0
            activeTaskId = nil
            armedActions = []
            phaseStart = Date()

        case let .tracking(taskId, phase, _):
            isActive = true
            activeTaskId = taskId
            activeTaskName = tracker.activeTask?.name ?? ""
            phaseLabel = phase.id.replacingOccurrences(of: "_", with: " ").capitalized
            armedActions = []

            // Icon: break phases use the cup symbol; work phases use timer.
            if phase.accrueAs == "break" {
                iconSymbol = "cup.and.saucer"
                iconColor = .blue
            } else {
                iconSymbol = "timer"
                iconColor = .primary
            }

            // Use tracker.phaseStartedAt — the wall-clock time when this phase
            // interval actually began. This is set by Tracker on start(),
            // advance(), and extend(). We do NOT derive it from
            // deadline - durationMin because extend() sets deadline = now +
            // extendMin (not now + durationMin), so the subtraction yields a
            // phaseStart in the wrong past, causing elapsedSeconds to jump by
            // (durationMin - extendMin) * 60 the instant the user taps '+15 min'.
            phaseStart = tracker.phaseStartedAt
            elapsedSeconds = Int(Date().timeIntervalSince(phaseStart))

        case let .armed(taskId, phase, _, armedAt):
            isActive = true
            activeTaskId = taskId
            activeTaskName = tracker.activeTask?.name ?? ""
            phaseLabel = phase.id.replacingOccurrences(of: "_", with: " ").capitalized + " (armed)"
            armedActions = phase.onArm.actions

            let (sym, col) = iconState(for: phase)
            iconSymbol = sym
            iconColor = col

            phaseStart = armedAt
            elapsedSeconds = Int(Date().timeIntervalSince(armedAt))
        }

        // Refresh task list and profiles from tracker (they change rarely).
        tasks = tracker.tasks.filter { $0.category != "break" }
        refreshProfilePublished()
    }

    // Mirrors profile-related @Published properties from the tracker's authoritative
    // state. Called at the end of updatePublished and after setProfile to ensure
    // both transition-driven and direct-mutation paths stay consistent.
    private func refreshProfilePublished() {
        profiles = tracker.profiles
        selectedProfileName = tracker.profileName
    }

    // Maps ArmConfig.color strings (from profiles.yaml) to SF Symbol names and
    // SwiftUI Colors. This is the ONLY place profile color strings are interpreted
    // as visual state — it lives at the app boundary where SwiftUI is permitted.
    private func iconState(for phase: Phase) -> (String, Color) {
        switch phase.onArm.color {
        case "green_pulse":
            return ("checkmark.circle", .green)
        case "amber":
            return ("exclamationmark.triangle", .orange)
        case "amber_pulse":
            return ("exclamationmark.triangle.fill", .orange)
        case "red":
            return ("exclamationmark.triangle.fill", .red)
        case "red_pulse":
            return ("exclamationmark.triangle.fill", .red)
        default:
            return ("timer", .primary)
        }
    }

    // MARK: - Public API (called by views)

    // select(taskId:) is the single entry point for user-initiated task selection.
    // Delegates unconditionally to tracker.switchTo(), which handles all three
    // TrackerState cases correctly:
    //   .idle    → start (fresh cycle)
    //   .tracking → switch (preserve current phase and deadline)
    //   .armed   → implicit advance then switch (no cycle reset)
    // Previously this called tracker.start() directly, which always reset the
    // phase cycle (stop() + iterator.reset()) on every task switch — violating
    // the DESIGN.md invariant "TRACKING → switch → TRACKING(task', same phase)".
    func select(taskId: Int64) {
        tracker.switchTo(taskId: taskId)
    }

    // Creates a new task in the DB, refreshes the task list, then starts it.
    // Throws AppStateError.taskNotFoundAfterInsert if the task cannot be found
    // immediately after upsert — this should never happen (upsert is synchronous),
    // but the explicit throw surfaces a real DB error path to the caller rather
    // than silently leaving the tracker in its previous state.
    func addAndStart(name: String) throws {
        // addTask returns the inserted Task with its id populated via didInsert.
        // Using the returned id avoids a name-search that would find the WRONG row
        // if two unarchived tasks share the same name (no UNIQUE constraint on name).
        let inserted = try tracker.addTask(name: name, code: nil)
        guard let id = inserted.id else {
            throw AppStateError.taskNotFoundAfterInsert(name: name)
        }
        // addTask refreshes tracker.tasks; sync our published list.
        tasks = tracker.tasks.filter { $0.category != "break" }
        // Use switchTo so a newly-started task doesn't reset the phase cycle
        // when the tracker is already running.
        tracker.switchTo(taskId: id)
    }

    func advance() {
        tracker.advance()
    }

    func extend(minutes: Int) {
        tracker.extend(minutes: minutes)
    }

    func stop() {
        tracker.stop()
    }

    func setProfile(_ name: String) {
        // Guard against the feedback loop where refreshProfilePublished() updates
        // selectedProfileName, which re-triggers the Picker's .onChange with the
        // already-current name. tracker.setProfile is idempotent for the same name
        // but appends a DB event — skip if the kit already agrees.
        guard name != tracker.profileName else { return }
        tracker.setProfile(name)
        // Sync immediately — tracker.setProfile may not emit a state event when idle
        // (no stop()/start() path runs), so updatePublished is never called.
        refreshProfilePublished()
    }

    func logInterruption(comment: String) {
        tracker.logInterruption(comment: comment)
    }

    // MARK: - History (Phase 6B)

    // Snapshot of recent per-day summaries, refreshed lazily when the history
    // panel is opened. Never refreshed on the 1 Hz tick (wasteful). Views read
    // this @Published property directly — no synchronous DB calls in body.
    @Published private(set) var history: [Store.DaySummary] = []

    // Fetches recent history into the published snapshot. Called from
    // HistoryView.onAppear (and/or when the history disclosure is toggled on)
    // so the data is always fresh when the panel is visible. Errors are swallowed
    // into an empty array — history is read-only and non-critical.
    func refreshHistory(days: Int = 7) {
        history = (try? store.recentReport(days: days)) ?? []
    }

    // MARK: - Reconcile (in-app reconcile UI)

    // MARK: - Report normalisation constants (DESIGN.md §"Report-layer time normalisation")
    // These are report-time parameters only — never baked into stored events.
    private enum NormConst {
        static let dropBelowSec  = 30   // intervals shorter than 30s are noise; drop
        static let minIntervalMin = 1   // floor surviving intervals to 1 minute
        static let roundToMin    = 15   // round per-key totals up to the next 15-min quantum
    }

    // Catch-all bucket for sub-quantum time rolled up via .rollIntoAggregate.
    // TODO(#30): make configurable; placeholder catch-all bucket
    private static let aggregateKey = "MISC"
    // Read-only accessor so views can display the key label without duplicating the literal.
    var aggregateKey: String { Self.aggregateKey }

    // Snapshots refreshed lazily when the reconcile panel opens. Views read these
    // directly — no store calls in body. All gate logic lives in AppState; the
    // view only renders and calls action methods.
    @Published private(set) var reconcileUnbound: [Store.UnreconciledTask] = []
    @Published private(set) var reconcileProvisional: [KnownTask] = []
    @Published private(set) var reconcileKnownTasks: [KnownTask] = []
    // True when both gates are clear after a refresh — the view reads this flag;
    // it never recomputes it. Avoids putting gate logic (&&) in the view.
    @Published private(set) var reconcileIsClean: Bool = false

    // Sub-15-minute candidates: JIRA keys whose post-pass-1 total < 15 min quantum.
    // Non-empty only when reconcileIsClean is true. Shrinks as user resolves rows.
    @Published private(set) var reconcileSubFifteen: [Store.SubFifteenItem] = []

    // User's resolution choices, keyed by jiraKey. Populated by setSubFifteenResolution.
    @Published private(set) var subFifteenResolutions: [String: Store.SubFifteenResolution] = [:]

    // Finalised normalised report preview given current resolutions.
    // Recomputed whenever resolutions change or reconcile refreshes.
    @Published private(set) var reconcileReportRows: [Store.ReconciledRow] = []

    // Trailing 14 calendar days: today (startOfDay) minus 13 days to today.
    // Rationale: CLI default ("today only") is too narrow for users who haven't
    // reconciled in a few days. 14 days covers two work weeks — the natural
    // timesheet submission cycle — without requiring scroll or a date picker.
    // One week risks missing Monday when opened on Friday after a full week.
    private var reconcileWindow: (from: Date, to: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -13, to: today)!
        return (from: from, to: today)
    }

    // Re-fetches all reconcile state from the store. Called from
    // ReconcileView.onAppear — synchronous GRDB on @MainActor, matching
    // refreshHistory's pattern. Errors swallow to empty arrays; if the store
    // throws the user sees an empty/clean panel which is a safe failure mode.
    func refreshReconcile() {
        // Sub-15 resolutions are per-session: a stale choice must never silently apply
        // to a later session (DESIGN.md — no silent billing decision). Reset on each refresh.
        subFifteenResolutions = [:]
        let w = reconcileWindow
        reconcileUnbound    = (try? store.unreconciled(from: w.from, to: w.to)) ?? []
        reconcileProvisional = (try? store.provisionalWithTime(from: w.from, to: w.to)) ?? []
        reconcileKnownTasks  = (try? store.knownTasks(activeOnly: true)) ?? []
        reconcileIsClean     = reconcileUnbound.isEmpty && reconcileProvisional.isEmpty

        if reconcileIsClean {
            // Compute the finalised report once. Resolutions were just reset above,
            // so every sub-quantum key is unresolved and therefore appears UNROUNDED
            // (< quantum) in the rows; the prompt list is derived from those rows,
            // avoiding a second full event-walk pass. reconciledReport rounds the
            // aggregate bucket up to the quantum, so it never shows up as a sub-15 row.
            reconcileReportRows = (try? store.reconciledReport(
                from: w.from, to: w.to,
                dropBelowSec: NormConst.dropBelowSec,
                minIntervalMin: NormConst.minIntervalMin,
                roundToMin: NormConst.roundToMin,
                aggregateKey: Self.aggregateKey,
                subFifteenResolutions: subFifteenResolutions)) ?? []

            let quantum = NormConst.roundToMin * 60
            reconcileSubFifteen = reconcileReportRows
                .filter { $0.jiraKey != Self.aggregateKey && $0.totalSeconds < quantum }
                .map { Store.SubFifteenItem(jiraKey: $0.jiraKey, totalSeconds: $0.totalSeconds) }
        } else {
            // Gates not clear — sub-15 data would be invalid (kit throws on gate failure).
            reconcileSubFifteen = []
            reconcileReportRows = []
        }
    }

    // Binds an ad-hoc capture task to a Known Task registry entry.
    // References the registry id (never the raw JIRA key) so a subsequent
    // promoteKnownTask call propagates to this binding automatically — invariant
    // from CLAUDE.md. Error is swallowed; refreshReconcile still runs so the
    // row stays visible if the bind failed (safe failure mode).
    func reconcileBind(taskId: Int64, knownTaskId: Int64) {
        try? store.bind(taskId: taskId, knownTaskId: knownTaskId, comment: nil)
        refreshReconcile()
    }

    // Promotes a provisional Known Task by assigning its real JIRA key.
    // Trimming and empty-key guard live here (not in the view) per CLAUDE.md
    // invariant 3. Matches the trimming pattern from TasksLoader (prior PR).
    func reconcilePromote(id: Int64, jiraKey: String) {
        let trimmed = jiraKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? store.promoteKnownTask(id: id, jiraKey: trimmed)
        refreshReconcile()
    }

    // Records the user's sub-15-minute resolution for a single JIRA key, then
    // recomputes the report preview. Removing the key from the candidate list
    // collapses the prompt row immediately (UX matches reconcileBind shrink).
    func setSubFifteenResolution(jiraKey: String, _ resolution: Store.SubFifteenResolution) {
        subFifteenResolutions[jiraKey] = resolution
        // Shrink the prompt list: resolved keys no longer need a decision.
        reconcileSubFifteen = reconcileSubFifteen.filter { $0.jiraKey != jiraKey }
        // Recompute the report preview with updated resolutions.
        let w = reconcileWindow
        reconcileReportRows = (try? store.reconciledReport(
            from: w.from, to: w.to,
            dropBelowSec: NormConst.dropBelowSec,
            minIntervalMin: NormConst.minIntervalMin,
            roundToMin: NormConst.roundToMin,
            aggregateKey: Self.aggregateKey,
            subFifteenResolutions: subFifteenResolutions)) ?? []
    }

    // Cached formatter for the dated fallback label. DateFormatter construction
    // is relatively expensive and dayLabel(for:) is called per row per redraw, so
    // one shared instance avoids repeated allocations.
    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d"
        return f
    }()

    // Formats a day Date as "Today", "Yesterday", or "Mon · Mar 15".
    // Lives here (not in the view) per CLAUDE.md invariant 3: no presentation
    // logic in views — Calendar/DateFormatter computations are logic, not rendering.
    func dayLabel(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day)     { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return Self.dayLabelFormatter.string(from: day)
    }

    // Formats a seconds count as a compact human-readable string.
    // Used by the history view; matches TaskRowView's todayAnnotation logic.
    func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let h = m / 60
        if h > 0 {
            return "\(h)h \(m % 60)m"
        } else if m > 0 {
            return "\(m)m"
        } else if seconds > 0 {
            return "<1m"
        } else {
            return "0m"
        }
    }

    // Relaunches the app by opening a NEW instance, then terminating this one.
    // Standard macOS menu-bar relaunch idiom.
    func relaunch() {
        // `open -n` forces a brand-new instance (plain `open` would only
        // re-activate the still-running current process). Run /usr/bin/open
        // directly — no shell, so no path quoting/escaping. -n also defeats the
        // re-activation race, so no artificial delay is needed: launchd spawns
        // the new instance independently of this process exiting.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            // Only quit if the relaunch was actually requested successfully;
            // otherwise leave the current instance running rather than stranding
            // the user with the app quit but not restarted.
            guard proc.terminationStatus == 0 else { return }
            NSApplication.shared.terminate(nil)
        } catch {
            return
        }
    }

    // MARK: - Config folder / YAML actions (#18)

    // Reveals the app-support data directory in Finder. Pairs with Restart:
    // the user edits a YAML here, then Restart re-ingests it.
    func revealConfigFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDir])
    }

    // Opens profiles.yaml in the user's default editor.
    func openProfilesYAML() {
        openYAML(named: "profiles.yaml")
    }

    // Opens tasks.yaml in the user's default editor.
    func openTasksYAML() {
        openYAML(named: "tasks.yaml")
    }

    // Opens a YAML file in the data dir with the default editor. If the file is
    // not present (tasks.yaml is optional; profiles.yaml may not exist on first
    // run), fall back to revealing the folder so the action never silently fails.
    private func openYAML(named filename: String) {
        let url = dataDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            revealConfigFolder()
        }
    }
}
#endif
