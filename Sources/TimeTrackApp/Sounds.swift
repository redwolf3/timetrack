#if canImport(AppKit)
import AppKit

enum Sounds {
    // Maps profile string names to macOS system sounds.
    // System sounds live at /System/Library/Sounds/ — names are without extension.
    // Tasteful defaults: Tink (gentle), Glass (clear), Hero (assertive).
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
#endif
