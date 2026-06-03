import Foundation

// Side effects the kit asks the app to perform. The kit stays platform-agnostic
// and Linux-buildable by emitting these instead of calling AppKit/UserNotifications
// directly; the app subscribes to Tracker.effectStream and executes them.
//
// IMPORTANT: AppState.subscribeToEffectStream() switches exhaustively over this enum.
// Adding a case here will cause a compile error there, intentionally forcing the
// new effect to be wired in the app layer before the build passes.
public enum Effect: Equatable {
    case playSound(String)   // NSSound name; app performs the play

    // Per DESIGN.md: escalation ceiling is a persistent notification, never a modal.
    // Emitted when an EscalationRung has notify: true. The app layer posts this
    // via UNUserNotificationCenter; re-posting the same notification identifier
    // replaces the existing one (persistent, not stacking).
    case postNotification(title: String, body: String)
}
