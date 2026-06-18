#if canImport(AppKit)
import Foundation
import ServiceManagement

// LoginItemManager wraps SMAppService.mainApp to provide a read/toggle
// interface for launch-at-login registration. Lives at the app boundary:
// SMAppService requires a proper .app bundle (bundle identifier must be
// non-nil); when running as a bare executable via `swift run` the register
// and unregister calls throw and isEnabled returns false gracefully — the
// toggle renders but remains off and non-functional without crashing.
//
// SMAppService.mainApp registers THIS executable's containing .app bundle as
// a login item in the user's login-items list (System Settings → General →
// Login Items). macOS 13+ only; we target macOS 14, so no availability guard.
final class LoginItemManager {

    // Returns true when SMAppService.mainApp.status == .enabled, meaning the
    // app is registered to launch at login. Any other status (including
    // .notFound, which occurs when running unbundled) maps to false so the
    // toggle stays off without crashing.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // Registers (enable == true) or unregisters (enable == false) the app as
    // a login item. Errors are logged and swallowed: the caller should
    // re-read isEnabled after the call to reflect the actual resulting state,
    // rather than assuming the requested state was applied.
    func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Log only — never crash. Common causes: running as a bare
            // executable (no bundle id), sandbox restrictions, or the system
            // rejecting the request. The toggle will reflect the actual
            // post-call status via the caller's re-read of isEnabled.
            NSLog("[TimeTrack] LoginItemManager: setEnabled(\(enable)) failed: \(error)")
        }
    }
}
#endif
