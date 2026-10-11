import Foundation
import Darwin

/// Single-instance mutex for enforce mode using BSD flock(2).
///
/// Only enforce mode (`enabled && !reportOnly`) acquires this lock; report-only
/// mode runs without locking so operators can run diagnostics freely.
public final class EnforceLock: @unchecked Sendable {
    public let url: URL
    private var fileDescriptor: Int32 = -1
    private let mutex = NSLock()

    public static let defaultLockURL: URL = {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".cache/earlyoom-mac/enforce.lock")
    }()

    public init(url: URL = EnforceLock.defaultLockURL) {
        self.url = url
    }

    deinit {
        release()
    }

    public var isHeld: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return fileDescriptor >= 0
    }

    public func acquire() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard fileDescriptor < 0 else { return }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EarlyoomError.cannotAcquireLock("cannot create lock directory \(directory.path): \(error)")
        }

        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw EarlyoomError.cannotAcquireLock("cannot open lock file \(url.path): \(String(cString: strerror(errno)))")
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            close(fd)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw EarlyoomError.lockAlreadyHeld("another earlyoom-mac instance is already running in enforce mode (lock: \(url.path))")
            } else {
                throw EarlyoomError.cannotAcquireLock("flock failed on \(url.path): \(String(cString: strerror(lockErrno)))")
            }
        }
        self.fileDescriptor = fd
    }

    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}
