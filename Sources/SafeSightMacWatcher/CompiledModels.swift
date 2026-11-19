// SPDX-License-Identifier: Apache-2.0
// Where the models' compiled copies live while the app runs, and how they are cleared away.
//
// Core ML compiles each model package before loading it, into the temporary folder, and never removes the copy:
// about 220 MB for the watcher's three models at every start (found in the Testing edition's safety pass,
// 19 November 2026: 144 such copies, 9.1 GB, had piled up on the developer Mac from lab runs). Each process now
// compiles into a folder of its own, removes it when it quits, and at start removes folders whose process has
// ended without quitting (a crash or a forced quit). A process marks its folder as in use with a lock that the
// system lets go of when the process ends, however it ends, so a folder still in use is never removed. Nothing
// outside folders with this prefix is ever touched. In the Testing edition the temporary folder is inside the
// app's sandbox container.
import Darwin
import Foundation

public final class CompiledModelFolder: @unchecked Sendable {
    /// Every folder made here starts with this.
    public static let prefix = "safesightmac-compiled-"
    static let lockName = ".in-use"
    /// A folder with no lock file is left alone this long (seconds): another process may have just made it and not yet
    /// taken its lock.
    static let unlockedGrace: TimeInterval = 3600

    public let url: URL
    private var lockFD: Int32 = -1
    private let lock = NSLock()

    /// Makes this process's folder in `parent` (the temporary folder by default) and marks it as in use.
    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.appendingPathComponent(Self.lockName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileLocking)
        }
        lockFD = fd
    }

    /// Removes the folder and everything compiled into it. Safe to call more than once.
    public func remove() {
        lock.lock(); defer { lock.unlock() }
        guard lockFD >= 0 else { return }
        close(lockFD)
        lockFD = -1
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the folders in `parent` left by processes that have ended, and returns them. A folder is left alone
    /// while its lock is held (its process is alive). Entries without the prefix, and symbolic links, are never touched.
    @discardableResult
    public static func sweep(parent: URL = FileManager.default.temporaryDirectory) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        var removed: [URL] = []
        for name in names where name.hasPrefix(prefix) {
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let fd = open(dir.appendingPathComponent(lockName).path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            if fd >= 0 {
                let free = flock(fd, LOCK_EX | LOCK_NB) == 0
                close(fd)
                guard free else { continue }   // its process is still running
            } else {
                // No lock file: removed only once it is old, never while its maker may still be starting.
                let made = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate]) as? Date
                guard let made, Date().timeIntervalSince(made) > unlockedGrace else { continue }
            }
            if (try? FileManager.default.removeItem(at: dir)) != nil { removed.append(dir) }
        }
        return removed
    }
}
