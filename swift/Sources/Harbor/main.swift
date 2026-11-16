import AppKit

// stdout is fully buffered (not line-buffered) when redirected to a file,
// as it is here via the launchd plist's StandardOutPath — print()
// statements can sit unflushed indefinitely for a long-running process,
// and a SIGTERM doesn't flush them either. Force line buffering so debug
// output actually lands in ~/.harbor/app.log in real time.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
