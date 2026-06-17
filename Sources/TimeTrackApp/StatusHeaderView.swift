#if canImport(AppKit)
import SwiftUI

// Read-only status display at the top of the popover.
// Shows the current tracker state derived entirely from AppState @Published
// properties — no TrackerState pattern-matching here.
struct StatusHeaderView: View {
    @EnvironmentObject var appState: AppState

    // Format elapsed seconds as MM:SS (under an hour) or H:MM:SS.
    private func formatElapsed(_ seconds: Int) -> String {
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: appState.iconSymbol)
                .foregroundStyle(appState.iconColor)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                statusLine
                if !appState.phaseLabel.isEmpty {
                    HStack(spacing: 4) {
                        Text(appState.phaseLabel)
                        // Cycle position ("2/4") for cyclic profiles — empty
                        // otherwise. Computed in AppState, not here.
                        if !appState.cyclePositionLabel.isEmpty {
                            Text(appState.cyclePositionLabel)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Elapsed + remaining — shown whenever tracking or armed.
            // Gate on activeTaskName, the canonical idle signal derived by
            // updatePublished, rather than elapsedSeconds which may briefly
            // lag a state transition and show a stale non-zero value.
            if !appState.activeTaskName.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatElapsed(appState.elapsedSeconds))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // Remaining-time readout, coloured by the same meter ramp.
                    // Hidden at 0 (armed/overrun) — elapsed already shows overrun.
                    if appState.remainingSeconds > 0 {
                        Text("\(appState.formatDuration(appState.remainingSeconds)) left")
                            .font(.caption2)
                            .foregroundStyle(appState.meterColor)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Time-remaining colour meter: a subtle fill that grows toward the
        // trailing edge as the deadline nears, tinted by phaseFraction. Width
        // and colour come from AppState; the view only draws them.
        .background(meterFill)
    }

    // Background meter fill behind the header (the "task+timer bar"). Only drawn
    // while tracking/armed; sits under the material so text stays legible.
    @ViewBuilder
    private var meterFill: some View {
        if !appState.activeTaskName.isEmpty {
            GeometryReader { geo in
                appState.meterColor
                    .opacity(0.18)
                    .frame(width: geo.size.width * appState.phaseFraction)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // The primary status line. Styling is driven by iconColor so the single
    // source of truth (AppState.updatePublished) controls all visual state.
    @ViewBuilder
    private var statusLine: some View {
        if appState.activeTaskName.isEmpty {
            Text("Idle")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else {
            Text(appState.activeTaskName)
                .font(.headline)
                .foregroundStyle(appState.iconColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
#endif
