import Foundation

/// UserDefaults keys and bounds for the contact list's Appearance
/// preferences: automatic window sizing and compact rows. Every reader binds
/// `@AppStorage` to these keys on the same store, which keeps them in sync.
public enum ContactListSizingDefaults {
    public static let autoSizeVerticalKey = "contactListAutoSizeVertical"
    public static let autoSizeHorizontalKey = "contactListAutoSizeHorizontal"
    public static let maxWidthKey = "contactListMaxWidth"
    public static let compactKey = "contactListCompact"

    /// Default value for the user's Maximum Width preference.
    public static let defaultMaxWidth: Double = 280
    /// Bounds of the Maximum Width slider (not the preference itself).
    public static let sliderMinWidth: Double = 150
    public static let sliderMaxWidth: Double = 400
}
