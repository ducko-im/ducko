import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.httpupload")

/// Implements XEP-0363 HTTP File Upload — discovers the upload service
/// and requests upload slots for file sharing.
public final class HTTPUploadModule: XMPPModule, Sendable {
    // MARK: - Types

    /// A negotiated upload slot with PUT and GET URLs.
    public struct UploadSlot: Sendable {
        public let putURL: String
        public let getURL: String
        public let putHeaders: [String: String]

        public init(putURL: String, getURL: String, putHeaders: [String: String] = [:]) {
            self.putURL = putURL
            self.getURL = getURL
            self.putHeaders = putHeaders
        }
    }

    /// Errors from the HTTP upload module.
    public enum HTTPUploadError: Error {
        case notConnected
        case noUploadServiceFound
        case fileTooLarge(maxSize: Int64)
        case slotRequestFailed(String)
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var cachedService: (jid: String, maxFileSize: Int64?)?
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.httpUpload]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.cachedService = nil }
    }

    // MARK: - Public API

    /// Discovers the HTTP upload service on the server via disco#items + disco#info.
    @discardableResult
    public func discoverUploadService() async throws -> (jid: String, maxFileSize: Int64?)? {
        if let cached = state.withLock({ $0.cachedService }) {
            return cached
        }

        guard let context = state.withLock({ $0.context }) else {
            throw HTTPUploadError.notConnected
        }

        guard let domainJID = JID.parse(context.domain) else { return nil }
        let items = try await ServiceDiscoveryModule.queryItems(for: domainJID, context: context)

        for item in items {
            let info: ServiceDiscoveryModule.InfoResult
            do {
                info = try await ServiceDiscoveryModule.queryInfo(for: item.jid, context: context)
            } catch {
                log.debug("Skipping disco#info for \(item.jid): \(error)")
                continue
            }
            if info.features.contains(XMPPNamespaces.httpUpload) {
                let maxFileSize = parseMaxFileSize(from: info.forms)
                let result = (jid: item.jid.description, maxFileSize: maxFileSize)
                state.withLock { $0.cachedService = result }
                log.info("Discovered an upload service, maxFileSize: \(maxFileSize.map(String.init) ?? "unlimited")")
                log.debug("The upload service is \(item.jid)")
                return result
            }
        }

        return nil
    }

    /// Requests an upload slot for the given file.
    public func requestSlot(
        filename: String,
        size: Int64,
        contentType: String
    ) async throws -> UploadSlot {
        guard let service = try await discoverUploadService() else {
            throw HTTPUploadError.noUploadServiceFound
        }

        if let maxSize = service.maxFileSize, size > maxSize {
            throw HTTPUploadError.fileTooLarge(maxSize: maxSize)
        }

        guard let context = state.withLock({ $0.context }) else {
            throw HTTPUploadError.notConnected
        }

        guard let serviceJID = JID.parse(service.jid) else {
            throw HTTPUploadError.slotRequestFailed("Invalid service JID: \(service.jid)")
        }

        var iq = XMPPIQ(type: .get, to: serviceJID, id: context.generateID())
        let request = XMLElement(
            name: "request",
            namespace: XMPPNamespaces.httpUpload,
            attributes: [
                "filename": filename,
                "size": String(size),
                "content-type": contentType
            ]
        )
        iq.element.addChild(request)

        guard let result = try await context.sendIQ(iq) else {
            throw HTTPUploadError.slotRequestFailed("Server returned error")
        }

        return try parseSlot(from: result)
    }

    // MARK: - Private: Discovery

    private func parseMaxFileSize(from forms: [[DataFormField]]) -> Int64? {
        for fields in forms {
            for field in fields where field.variable == "max-file-size" {
                if let size = field.values.first.flatMap(Int64.init) {
                    return size
                }
            }
        }
        return nil
    }

    // MARK: - Private: Slot Parsing

    private func parseSlot(from element: XMLElement) throws -> UploadSlot {
        guard let putElement = element.child(named: "put"),
              let putURL = putElement.attribute("url") else {
            throw HTTPUploadError.slotRequestFailed("Missing PUT URL")
        }

        guard let getElement = element.child(named: "get"),
              let getURL = getElement.attribute("url") else {
            throw HTTPUploadError.slotRequestFailed("Missing GET URL")
        }

        var putHeaders: [String: String] = [:]
        for header in putElement.children(named: "header") {
            guard let rawName = header.attribute("name"), let rawValue = header.textContent else { continue }
            let lowercasedName = rawName.filter { !$0.isNewline }.lowercased()
            guard let name = Self.allowedPutHeaders.first(where: { $0.lowercased() == lowercasedName }) else { continue }
            let value = rawValue.filter { !$0.isNewline }
            // Cookie pairs join with "; " (RFC 6265 §5.4); other repeated fields join as a list (RFC 9110 §5.3).
            let separator = name == "Cookie" ? "; " : ", "
            putHeaders[name] = putHeaders[name].map { $0 + separator + value } ?? value
        }

        return UploadSlot(putURL: putURL, getURL: getURL, putHeaders: putHeaders)
    }

    /// The only slot headers XEP-0363 lets a client apply to the PUT request.
    private static let allowedPutHeaders = ["Authorization", "Cookie", "Expires"]
}
