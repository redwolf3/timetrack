#if canImport(AppKit)
import AppKit
import CoreGraphics
import TimeTrackKit

// The real macOS idle source — measures seconds since last user input via
// CoreGraphics. Lives in TimeTrackApp (not TimeTrackKit) because it touches
// platform APIs. Injected into Tracker at app startup.
// Measures WHEN, never WHAT — no permission required.
final class SystemIdleSource: IdleSource {
    func idleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
#endif
