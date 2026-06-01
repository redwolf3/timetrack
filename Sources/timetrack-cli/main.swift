import Foundation
import TimeTrackCLICore

// Thin executable shell. All command logic lives in TimeTrackCLICore (a library
// target) so it can be imported and exercised by unit tests — SwiftPM executable
// targets cannot be imported by test targets.
//
// This shell's only jobs are: (1) hop onto the main actor, (2) forward argv
// (minus the executable name) to CLI.run, and (3) translate the outcome into the
// process exit code — exit(0) on success, exit(1) on any thrown error. The core
// never calls exit() itself; that contract lives here.
//
// Dispatch onto the main actor and keep the RunLoop alive until exit() is called.
// All Store operations are synchronous; the Task executes and then calls exit(0).
// The @MainActor annotation is included for forward-compatibility with Tracker use.
_Concurrency.Task { @MainActor in
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
