import Foundation

public struct LinkPreview: Sendable, Equatable {
    public var url: String
    public var title: String?
    public var descriptionText: String?
    public var imageURL: String?
    public var siteName: String?
    public var fetchedAt: Date

    public init(
        url: String,
        title: String? = nil,
        descriptionText: String? = nil,
        imageURL: String? = nil,
        siteName: String? = nil,
        fetchedAt: Date
    ) {
        self.url = url
        self.title = title
        self.descriptionText = descriptionText
        self.imageURL = imageURL
        self.siteName = siteName
        self.fetchedAt = fetchedAt
    }
}
