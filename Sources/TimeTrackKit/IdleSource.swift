import Foundation

// The injection seam. TimeTrackKit never calls CoreGraphics directly — it asks
// an IdleSource how many seconds since the last user input. The real macOS
// implementation (CGEventSourceSecondsSinceLastEventType) lives in the app
// target; tests inject a fake that returns scripted values. This keeps the
// idle-segmentation and escalation logic — where the subtle bugs live — fully
// testable without a live macOS session.
public protocol IdleSource {
    // Seconds since the last keyboard/mouse/trackpad event. Measures WHEN, never
    // WHAT — no input content, no permission required by the real implementation.
    func idleSeconds() -> TimeInterval
}

// Deterministic fake for tests: scripted idle readings, advanced manually.
public final class FakeIdleSource: IdleSource {
    private var script: [TimeInterval]
    private var cursor = 0
    private var last: TimeInterval = 0

    public init(_ script: [TimeInterval] = []) { self.script = script }

    public func idleSeconds() -> TimeInterval {
        guard cursor < script.count else { return last }
        last = script[cursor]
        cursor += 1
        return last
    }

    // Convenience for tests that want to set a steady value.
    public func set(_ v: TimeInterval) { script = [v]; cursor = 0; last = v }
}
