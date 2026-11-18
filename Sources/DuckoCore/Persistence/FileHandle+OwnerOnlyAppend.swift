import Foundation

extension FileHandle {
    /// Opens the file at `url` for appending, creating it owner-only (0600) when missing. Every write lands at the end
    /// of the file, so processes appending to it at once add to each other's records rather than overwrite them.
    static func openOwnerOnlyForAppending(at url: URL) throws -> FileHandle {
        let path = url.path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            let posixError = POSIXError(.init(rawValue: errno) ?? .ENOENT)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: posixError
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
