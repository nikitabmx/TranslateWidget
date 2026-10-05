import Foundation

/// Tiny append-only file logger for diagnosing the dictation crash.
/// Writes to /tmp/tw-debug.log. Safe to remove once the issue is fixed.
enum DebugLog {
    static let path = "/tmp/tw-debug.log"

    static func log(_ message: String) {
        let line = "\(Self.stamp())  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Installs handlers so an uncaught exception or fatal signal is recorded
    /// before the process dies (SIGKILL can't be caught — its absence is a clue).
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            DebugLog.log("‼️ UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")")
            DebugLog.log(exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGFPE] {
            signal(sig) { received in
                DebugLog.log("‼️ FATAL SIGNAL \(received)")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        DebugLog.log("=== launch; crash handlers installed ===")
    }
}
