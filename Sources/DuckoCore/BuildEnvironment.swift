import Foundation

public enum BuildEnvironment {
    /// Pure helper that resolves the Application Support folder name from a profile + build flag.
    /// Internal so tests can exercise both DEBUG and release branches without exposing a stable
    /// public API; tests reach it via `@testable import DuckoCore`.
    static func computeAppSupportDirectoryName(profile: String?, isDebug: Bool) -> String {
        guard isDebug else { return "Ducko" }
        if let profile { return "Ducko-Dev-\(profile)" }
        return "Ducko-Dev"
    }

    /// Pure helper that resolves the UserDefaults suite name from a profile + build flag.
    /// Returns `nil` for release builds (so callers fall back to `.standard`).
    static func computeUserDefaultsSuiteName(profile: String?, isDebug: Bool) -> String? {
        guard isDebug else { return nil }
        if let profile { return "im.ducko.dev.\(profile)" }
        return "im.ducko.dev"
    }

    /// Pure helper that resolves whether Jingle offers direct candidates from the `DUCKO_JINGLE_PROXY_ONLY` value + build
    /// flag. Only a debug build withholds them, so a local transfer has to go through the server's proxy.
    static func computeJingleOffersDirectCandidates(proxyOnly: String?, isDebug: Bool) -> Bool {
        guard isDebug else { return true }
        return proxyOnly != "1"
    }

    #if DEBUG
        private static let profileName = ProcessInfo.processInfo.environment["DUCKO_PROFILE"]
        public static let appSupportDirectoryName = computeAppSupportDirectoryName(profile: profileName, isDebug: true)
        public static let useKeychain = ProcessInfo.processInfo.environment["DUCKO_USE_KEYCHAIN"] == "1"
        public static let userDefaultsSuiteName: String? = computeUserDefaultsSuiteName(profile: profileName, isDebug: true)
        public static let jingleOffersDirectCandidates = computeJingleOffersDirectCandidates(
            proxyOnly: ProcessInfo.processInfo.environment["DUCKO_JINGLE_PROXY_ONLY"], isDebug: true
        )
    #else
        public static let appSupportDirectoryName = computeAppSupportDirectoryName(profile: nil, isDebug: false)
        public static let useKeychain = true
        public static let userDefaultsSuiteName: String? = computeUserDefaultsSuiteName(profile: nil, isDebug: false)
        public static let jingleOffersDirectCandidates = computeJingleOffersDirectCandidates(proxyOnly: nil, isDebug: false)
    #endif

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }
}
