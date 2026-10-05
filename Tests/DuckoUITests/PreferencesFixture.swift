import Foundation

final class PreferencesFixture {
    private let suiteName = "im.ducko.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        self.defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
