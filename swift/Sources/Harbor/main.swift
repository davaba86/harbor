import AppKit

// stdout is fully buffered (not line-buffered) when redirected to a file,
// as it is here via the launchd plist's StandardOutPath — print()
// statements can sit unflushed indefinitely for a long-running process,
// and a SIGTERM doesn't flush them either. Force line buffering so debug
// output actually lands in ~/.harbor/app.log in real time.
setvbuf(stdout, nil, _IOLBF, 0)

// Objective-C-level uncaught exceptions (e.g. AppKit/Foundation API misuse)
// otherwise just terminate silently with nothing in app.log — this is the
// one place that can still log something before the process dies. Swift
// traps (force-unwrap, array out-of-bounds, etc.) crash below this layer
// and won't go through here; the system crash report is still the source
// of truth for those.
NSSetUncaughtExceptionHandler { exception in
    harborLog("UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "no reason") \(exception.callStackSymbols.joined(separator: "\n"))")
}

harborLog("Harbor starting (pid \(ProcessInfo.processInfo.processIdentifier))")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
