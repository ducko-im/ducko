import Darwin
import DuckoCore

enum CredentialHelper {
    /// The buffer a hidden line is read into. A line that fills it may have been cut off, so it is refused.
    static let hiddenLineBufferSize = 4096

    /// Returns a password using a two-tier fallback:
    /// 1. Credential store (if JID and store provided)
    /// 2. Interactive prompt via `readHiddenLine` (if running in a TTY), which throws for a password too long to read
    ///    whole
    static func getPassword(for jid: String? = nil, using store: (any CredentialStore)? = nil) throws -> String? {
        if let jid, let store, let stored = store.loadPassword(for: jid) {
            return stored
        }
        return try readHiddenLine(prompt: "Password: ")
    }

    /// Reads one line from the terminal without echoing it, or returns nil when not running in a TTY.
    static func readHiddenLine(prompt: String) throws -> String? {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: hiddenLineBufferSize)
        let line = buffer.withUnsafeMutableBufferPointer { buffer in
            readpassphrase(prompt, buffer.baseAddress, buffer.count, RPP_ECHO_OFF).map { String(cString: $0) }
        }
        return try line.map(wholeHiddenLine)
    }

    /// `line` as read into the hidden-line buffer, refused when it filled the buffer.
    static func wholeHiddenLine(_ line: String) throws -> String {
        guard line.utf8.count < hiddenLineBufferSize - 1 else {
            throw CLIError.hiddenInputTooLong(maxBytes: hiddenLineBufferSize - 2)
        }
        return line
    }
}
