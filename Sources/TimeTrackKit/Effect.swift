import Foundation

// Side effects the kit asks the app to perform. The kit stays platform-agnostic
// and Linux-buildable by emitting these instead of calling AppKit/UserNotifications
// directly; the app subscribes to Tracker.effectStream and executes them.
//
// Phase 1 ships .playSound only — the single existing side effect (phase-arm chime).
// .postNotification and .setIcon enter the enum when Phase 5 needs them; adding a
// case is source-compatible with existing consumers as long as switches are
// non-exhaustive at the boundary.
public enum Effect: Equatable {
    case playSound(String)   // NSSound name; app performs the play
}
