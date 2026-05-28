import Foundation
import AppKit
import TimeTrackKit

// The real macOS idle source — the CoreGraphics call removed from TimeTrackKit.
// Lives here because it touches platform APIs; injected into IdleMonitor.
// Measures seconds since last input (WHEN, not WHAT); no permission required.
final class SystemIdleSource: IdleSource {
    func idleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        return CGEventSourceSecondsSinceLastEventType(.combinedSessionState, anyEvent)
    }
}

// Phase 5 builds the MenuBarExtra app here. Placeholder so the target exists.
// Do NOT flesh this out before Phases 1–3 are merged and green.
@main
struct TimeTrackAppMain {
    static func main() {
        // Phase 5: replace with SwiftUI App { MenuBarExtra { ... } }.
        // Wire: SystemIdleSource -> IdleMonitor; kit Effect stream -> Sounds.play,
        // UserNotifications, icon state.
        fatalError("TimeTrackApp not yet implemented — see INITIAL_PROMPT.md Phase 5")
    }
}
