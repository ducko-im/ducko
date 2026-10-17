import Foundation
import Logging
import Synchronization

/// swift-log `LogHandler` writing to a rotating file via a shared `FileLogWriter` (`maxFileSize`/`maxArchivedFiles`).
/// `logLevel` is pinned to `.trace` so `MultiplexLogHandler` passes everything through; real filtering runs dynamically via
/// `minimumLevelProvider` (reads UserDefaults for runtime toggling without re-bootstrapping).
struct FileLogHandler: LogHandler {
    private let label: String
    private let writer: FileLogWriter
    private let minimumLevelProvider: @Sendable () -> Logger.Level

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    init(label: String, writer: FileLogWriter, minimumLevel: @escaping @Sendable () -> Logger.Level) {
        self.label = label
        self.writer = writer
        self.minimumLevelProvider = minimumLevel
    }

    func log(event: LogEvent) {
        guard event.level >= minimumLevelProvider() else { return }

        let timestamp = Date.now.formatted(Self.timestampStyle)
        let levelTag = event.level.rawValue.uppercased()
        let logLine = "[\(timestamp)] [\(levelTag)] [\(label)] \(event.message)\n"

        // Write inline so log lines stay in the order callers emitted them. The writer's
        // internal lock makes concurrent emitters serialize; offloading via `Task` would
        // hand them to the cooperative pool and re-order them.
        writer.write(logLine)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

// MARK: - File Log Writer

/// Serialized file writer with size-based rotation. The mutable `FileHandle` is wrapped in a
/// `Synchronization.Mutex` so the writer is `Sendable` without resorting to `@unchecked`, while
/// `FileLogHandler.log` can still call `write(_:)` synchronously and preserve emission order.
public final class FileLogWriter: Sendable {
    public static let defaultFileName = "ducko.log"

    private let directory: URL
    private let fileName: String
    private let maxFileSize: UInt64
    private let maxArchivedFiles: Int
    private let handleState: Mutex<FileHandle?>

    public init(
        directory: URL,
        fileName: String = FileLogWriter.defaultFileName,
        maxFileSize: UInt64 = 5 * 1024 * 1024,
        maxArchivedFiles: Int = 5
    ) {
        self.directory = directory
        self.fileName = fileName
        self.maxFileSize = maxFileSize
        self.maxArchivedFiles = maxArchivedFiles
        self.handleState = Mutex<FileHandle?>(nil)
    }

    public var currentLogFile: URL {
        directory.appendingPathComponent(fileName)
    }

    /// All log files (current + archived), sorted by recency.
    public var allLogFiles: [URL] {
        var files: [URL] = []
        let current = currentLogFile
        if FileManager.default.fileExists(atPath: current.path) {
            files.append(current)
        }
        for i in 1 ... maxArchivedFiles {
            let archived = archivedFile(index: i)
            if FileManager.default.fileExists(atPath: archived.path) {
                files.append(archived)
            }
        }
        return files
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        handleState.withLock { handle in
            guard let active = ensureFileHandle(&handle) else { return }
            try? active.write(contentsOf: data)
            rotateIfNeeded(&handle)
        }
    }

    // MARK: - Rotation

    private func rotateIfNeeded(_ handle: inout FileHandle?) {
        guard let active = handle, let size = try? active.offset(), size >= maxFileSize else { return }

        try? active.close()
        handle = nil

        // Shift archived files: N → N+1, delete oldest if over limit
        let fm = FileManager.default
        let oldest = archivedFile(index: maxArchivedFiles)
        try? fm.removeItem(at: oldest)

        for i in stride(from: maxArchivedFiles - 1, through: 1, by: -1) {
            let src = archivedFile(index: i)
            let dst = archivedFile(index: i + 1)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Current → .1
        try? fm.moveItem(at: currentLogFile, to: archivedFile(index: 1))
    }

    private func archivedFile(index: Int) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return directory.appendingPathComponent("\(base).\(index).\(ext)")
    }

    private func ensureFileHandle(_ handle: inout FileHandle?) -> FileHandle? {
        if let existing = handle {
            return existing
        }

        let fm = FileManager.default
        let file = currentLogFile

        try? fm.createOwnerOnlyDirectory(at: directory)

        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        guard let opened = FileHandle(forWritingAtPath: file.path) else { return nil }
        try? opened.seekToEnd()
        handle = opened
        return opened
    }
}
