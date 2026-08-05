import Darwin
import Foundation

/// A terminal only knows which directory a tab is in because the shell tells
/// it, via OSC 7, each time it draws a prompt. An agent started in the same
/// breath as its `cd` (`cd project && claude`) never gives the shell that
/// chance, so the tab keeps reporting wherever the shell stood before — and
/// MegaMicro, which finds Ghostty tabs by directory, sends the project's key
/// to the wrong tab or to none at all.
///
/// The kernel knows better: the agent process itself has the real working
/// directory and a controlling terminal. Read one, write the other, and the
/// tab starts describing itself accurately — to MegaMicro and to Ghostty's own
/// UI. This is the same message a shell sends; nothing about it is a fiction.
enum TerminalDirectoryReporter {
    struct Correction {
        let tty: String
        let path: String
    }

    /// Announces the true directory of every terminal running a process inside
    /// `path`, and returns what it corrected. Processes with no controlling
    /// terminal (daemons, the agent's own subprocesses) are skipped.
    @discardableResult
    static func announceDirectories(under path: String, limit: Int = 8) -> [Correction] {
        let target = normalized(path)
        guard !target.isEmpty else { return [] }

        var seen = Set<String>()
        var corrections: [Correction] = []
        for pid in runningProcessIDs() {
            guard let cwd = workingDirectory(of: pid) else { continue }
            let candidate = normalized(cwd)
            guard candidate == target || candidate.hasPrefix(target + "/") else { continue }
            guard let tty = controllingTerminal(of: pid), seen.insert(tty).inserted else { continue }
            guard announce(directory: cwd, toTerminal: tty) else { continue }
            corrections.append(Correction(tty: tty, path: cwd))
            if corrections.count >= limit { break }
        }
        return corrections
    }

    /// macOS paths are case-insensitive and the directory can arrive from a
    /// hook, a drag, or the kernel with any casing.
    private static func normalized(_ path: String) -> String {
        var value = path.lowercased()
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func runningProcessIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        // Headroom for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                                Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size > 0 else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    private static func controllingTerminal(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func announce(directory: String, toTerminal tty: String) -> Bool {
        guard let encoded = directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return false }
        // O_NOCTTY: describing someone else's terminal must never adopt it.
        // O_NONBLOCK: a wedged tab can never stall the key press.
        let descriptor = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Ghostty ignores a directory it reads as remote, and decides that by
        // matching the authority against the local hostname exactly — the
        // lowercase form `ProcessInfo.hostName` returns is rejected, as is an
        // empty authority. `localhost` always names this machine.
        let sequence = Array("\u{1b}]7;file://localhost\(encoded)\u{7}".utf8)
        let written = sequence.withUnsafeBufferPointer {
            write(descriptor, $0.baseAddress, $0.count)
        }
        return written == sequence.count
    }
}
