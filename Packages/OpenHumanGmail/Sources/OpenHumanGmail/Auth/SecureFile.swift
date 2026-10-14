import Foundation

// Create the temp file with O_EXCL and the final mode, then rename, so a secret is never exposed with a looser mode
enum SecureFile {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "\(operation) failed (errno \(code))" }
    }

    static func ensureDirectory(_ url: URL, mode: mode_t, tighten: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure(operation: "not a directory", code: ENOTDIR) }
            if tighten, (info.st_mode & 0o077) != 0, chmod(url.path, mode) != 0 {
                throw Failure(operation: "chmod directory", code: errno)
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: mode)])
        if chmod(url.path, mode) != 0 { throw Failure(operation: "chmod directory", code: errno) }
    }

    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure(operation: "open", code: errno) }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        guard fchmod(fd, mode) == 0 else {
            let code = errno
            close(fd)
            throw Failure(operation: "fchmod", code: code)
        }
        let written: Bool = data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= n
                base = base.advanced(by: n)
            }
            return true
        }
        guard written else {
            let code = errno
            close(fd)
            throw Failure(operation: "write", code: code)
        }
        _ = fsync(fd)
        close(fd)
        guard rename(temp.path, url.path) == 0 else { throw Failure(operation: "rename", code: errno) }
        ok = true
    }

    enum Kind: Equatable { case missing, regularFile, other }

    // lstat so symlinks are reported as .other and never followed
    static func inspect(_ url: URL) -> (kind: Kind, mode: mode_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return (.missing, 0) }
        let kind: Kind = (info.st_mode & S_IFMT) == S_IFREG ? .regularFile : .other
        return (kind, info.st_mode & 0o7777)
    }

    static func permissions(of url: URL) -> mode_t? {
        let result = inspect(url)
        return result.kind == .missing ? nil : result.mode
    }
}
