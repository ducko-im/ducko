import Foundation

@MainActor @Observable
public final class OMEMOPreferences {
    private enum Keys {
        static let trustOnFirstUse = "omemoTrustOnFirstUse"
        static let encryptByDefault = "omemoEncryptByDefault"
    }

    private static let defaults = PreferencesDefaults.store

    public static let shared = OMEMOPreferences()

    public var trustOnFirstUse: Bool {
        didSet { Self.defaults.set(trustOnFirstUse, forKey: Keys.trustOnFirstUse) }
    }

    public var encryptByDefault: Bool {
        didSet { Self.defaults.set(encryptByDefault, forKey: Keys.encryptByDefault) }
    }

    private init() {
        let storedTOFU = Self.defaults.object(forKey: Keys.trustOnFirstUse) as? Bool
        self.trustOnFirstUse = storedTOFU ?? true
        let storedDefault = Self.defaults.object(forKey: Keys.encryptByDefault) as? Bool
        self.encryptByDefault = storedDefault ?? false
    }
}
