import Foundation

/// Minimal timestamped logger. Writes to stdout, which launchd redirects to
/// ~/.harbor/app.log (see main.swift's setvbuf comment for why line
/// buffering matters here) — no separate log file or framework needed.
func harborLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(formatter.string(from: Date()))] \(message)")
}
