import XCTest
@testable import TimeTrackKit

// Starter suite. Phase 2 expands this to cover the state machine and idle
// segmentation; Phase 3 covers the reconcile gate. The point of FakeIdleSource
// is that all of this runs on Linux with zero real macOS session.
final class TimeTrackKitTests: XCTestCase {

    // Sanity: the fake returns scripted idle readings in order, then holds last.
    func testFakeIdleSourceScript() {
        let idle = FakeIdleSource([0, 30, 600])
        XCTAssertEqual(idle.idleSeconds(), 0)
        XCTAssertEqual(idle.idleSeconds(), 30)
        XCTAssertEqual(idle.idleSeconds(), 600)
        XCTAssertEqual(idle.idleSeconds(), 600)   // holds last
    }

    // Phase 2 TODO: idle below wiggleRoomMin opens no episode.
    // Phase 2 TODO: idle >= threshold -> episode, idleStart == now - idleSeconds.
    // Phase 2 TODO: two-segment split + collapse cases.
    // Phase 2 TODO: strict in-window break emits no idle_resolve.
    // Phase 2 TODO: presence-gated escalation advances only on active-seconds.
    // Phase 3 TODO: provisional promote propagates to existing binds.
    // Phase 3 TODO: two-condition gate throws .unbound and .provisional correctly.
    // Phase 3 TODO: idle reattribution interval math across a multi-day window.
}
