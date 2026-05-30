import Foundation
import TimeTrackKit

// Dispatch onto the main actor and keep the RunLoop alive until exit() is called.
// All Store operations are synchronous; the Task executes and then calls exit(0).
// The @MainActor annotation is included for forward-compatibility with Tracker use.
Task { @MainActor in
    do {
        try CLI.run(args: Array(CommandLine.arguments.dropFirst()))
    } catch let e as CLIError {
        fputs("error: \(e.description)\n", stderr)
        exit(1)
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}
dispatchMain()
