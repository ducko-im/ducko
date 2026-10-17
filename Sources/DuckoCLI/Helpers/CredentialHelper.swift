import Darwin
import DuckoCore

enum CredentialHelper {
    /// Returns a password using a two-tier fallback:
    /// 1. Credential store (if JID and store provided)
    /// 2. Interactive prompt via `getpass()` (if running in a TTY)
    static func getPassword(for jid: String? = nil, using store: (any CredentialStore)? = nil) -> String? {
        if let jid, let store, let stored = store.loadPassword(for: jid) {
            return stored
        }
        guard isatty(STDIN_FILENO) != 0, let cString = getpass("Password: ") else { return nil }
        return String(cString: cString)
    }
}
