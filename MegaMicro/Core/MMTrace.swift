import Foundation

/// Unbuffered diagnostic trace.
///
/// `print` writes to stdout, which macOS block-buffers when the app is
/// launched with its output redirected — so messages sit in a buffer and never
/// appear when you need them. stderr is unbuffered, so this shows up
/// immediately even if the app hangs or is force-quit.
enum MMTrace {
    static func log(_ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data("[MM] \(message())\n".utf8))
    }
}
