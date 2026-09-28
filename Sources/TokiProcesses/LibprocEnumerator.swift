/// libproc-backed `ProcessEnumerating` — the production process source.
///
/// Reads, for every pid the current user may inspect:
///   - executable path      (`proc_pidpath`)               — required; pid skipped if it fails
///   - working directory     (`proc_pidinfo` PROC_PIDVNODEPATHINFO) — best-effort
///   - start time            (`proc_pidinfo` PROC_PIDTBSDINFO)      — best-effort
///   - resident memory (RSS) (`proc_pidinfo` PROC_PIDTASKINFO)      — best-effort
///
/// All per-pid failures (EPERM on other users' processes, dead pids, missing
/// vnode info) are swallowed: a pid with a readable exe path is returned even
/// if the optional facts couldn't be read. No `claude` filtering happens here.
import Darwin
import Foundation

public struct LibprocEnumerator: ProcessEnumerating {
    public init() {}

    public func enumerate() -> [RawProcess] {
        let pids = allPIDs()
        var result: [RawProcess] = []
        result.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let path = executablePath(pid) else { continue }
            result.append(
                RawProcess(
                    pid: pid,
                    executablePath: path,
                    workingDirectory: workingDirectory(pid),
                    startedAt: startedAt(pid),
                    memoryBytes: residentMemory(pid)
                )
            )
        }
        return result
    }

    // MARK: - pid list

    private func allPIDs() -> [Int32] {
        // First call with a nil buffer to learn the required byte count.
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var buffer = [pid_t](repeating: 0, count: capacity)

        let written = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return [] }

        let returnedCount = Int(written) / MemoryLayout<pid_t>.stride
        return Array(buffer.prefix(returnedCount))
    }

    // MARK: - per-pid facts

    /// `PROC_PIDPATHINFO_MAXSIZE` (== 4 * MAXPATHLEN) — the C macro isn't
    /// imported into Swift, so we recreate it from MAXPATHLEN.
    private static let pathInfoMaxSize = Int(MAXPATHLEN) * 4

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.pathInfoMaxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(Self.pathInfoMaxSize))
        guard length > 0 else { return nil } // EPERM / dead pid
        // Read up to the NUL terminator. String(validatingCString:) is deprecated and
        // its replacement needs macOS 15; String(cString:) is the non-deprecated pointer
        // form already used by workingDirectory() below.
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard read == size else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    private func startedAt(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        guard info.pbi_start_tvsec > 0 else { return nil }

        let seconds = TimeInterval(info.pbi_start_tvsec)
        let micros = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + micros)
    }

    private func residentMemory(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard read == size else { return nil }
        return info.pti_resident_size
    }
}
