import Foundation
import TimeTrackKit

#if canImport(AppKit)
import AppKit

// The real macOS idle source — the CoreGraphics call removed from TimeTrackKit.
// Lives here because it touches platform APIs; injected into IdleMonitor.
// Measures seconds since last input (WHEN, not WHAT); no permission required.
final class SystemIdleSource: IdleSource {
    func idleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
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
#else
// Linux build: TimeTrackApp is a macOS-only menu-bar app. The target still has
// to produce an executable so `swift build` works on cloud (Linux) sessions —
// this stub does that. Phase 5 work happens on macOS.
@main
struct TimeTrackAppMain {
    static func main() {
        fatalError("TimeTrackApp requires macOS — build TimeTrackKit / timetrack-cli on Linux instead")
    }
}
#endif
