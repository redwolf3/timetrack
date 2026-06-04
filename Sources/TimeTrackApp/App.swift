import Foundation

#if canImport(AppKit)
import SwiftUI
import TimeTrackKit
import UserNotifications

// Returns the App Support directory for TimeTrack, honouring the
// TIMETRACK_DATA_DIR env var override used in tests and dev sessions.
private func dataDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["TIMETRACK_DATA_DIR"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("timetrack", isDirectory: true)
}

@main
struct TimeTrackSwiftUIApp: App {
    @StateObject private var appState: AppState = {
        let dir = dataDirectory()
        let dbURL = dir.appendingPathComponent("events.db")
        let profilesURL = dir.appendingPathComponent("profiles.yaml")
        do {
            let store = try Store(url: dbURL)
            return try AppState(store: store, profilesURL: profilesURL)
        } catch {
            fatalError("TimeTrackApp: failed to open store or init AppState: \(error)")
        }
    }()

    var body: some Scene {
        MenuBarExtra("TimeTrack", systemImage: appState.iconSymbol) {
            MenuBarPopoverView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

#else
// Linux build: TimeTrackApp is a macOS-only menu-bar app. The target still has
// to produce an executable so `swift build` works on cloud (Linux) sessions —
// this stub does that.
@main
struct TimeTrackAppMain {
    static func main() {
        fatalError("TimeTrackApp requires macOS — build TimeTrackKit / timetrack-cli on Linux instead")
    }
}
#endif
