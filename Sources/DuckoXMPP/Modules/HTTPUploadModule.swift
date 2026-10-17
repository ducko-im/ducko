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

        let items = try await queryItems(context: context)

        for item in items {
            let info: DiscoInfoResult
            do {
                info = try await queryInfo(for: item, context: context)
            } catch {
                log.debug("Skipping disco#info for \(item): \(error)")
                continue
            }
            if info.features.contains(XMPPNamespaces.httpUpload) {
                let maxFileSize = parseMaxFileSize(from: info.extensions)
                let result = (jid: item, maxFileSize: maxFileSize)
                state.withLock { $0.cachedService = result }
                log.info("Discovered an upload service, maxFileSize: \(maxFileSize.map(String.init) ?? "unlimited")")
                log.debug("The upload service is \(item)")
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

    private func queryItems(context: ModuleContext) async throws -> [String] {
        guard let domainJID = JID.parse(context.domain) else { return [] }

        var iq = XMPPIQ(type: .get, to: domainJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return result.children(named: "item").compactMap { $0.attribute("jid") }
    }

    private struct DiscoInfoResult {
        let features: Set<String>
        let extensions: [XMLElement]
    }

    private func queryInfo(for jid: String, context: ModuleContext) async throws -> DiscoInfoResult {
        guard let targetJID = JID.parse(jid) else {
            return DiscoInfoResult(features: [], extensions: [])
        }

        var iq = XMPPIQ(type: .get, to: targetJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            return DiscoInfoResult(features: [], extensions: [])
        }

        var features = Set<String>()
        for element in result.children(named: "feature") {
            if let featureVar = element.attribute("var") {
                features.insert(featureVar)
            }
        }

        let extensions = result.children(named: "x").filter {
            $0.namespace == XMPPNamespaces.dataForms
        }

        return DiscoInfoResult(features: features, extensions: extensions)
    }

    private func parseMaxFileSize(from extensions: [XMLElement]) -> Int64? {
        for form in extensions {
            for field in form.children(named: "field") {
                guard field.attribute("var") == "max-file-size" else { continue }
                if let valueElement = field.child(named: "value"),
                   let text = valueElement.textContent,
                   let size = Int64(text) {
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
            if let name = header.attribute("name"), let value = header.textContent {
                putHeaders[name] = value
            }
        }

        return UploadSlot(putURL: putURL, getURL: getURL, putHeaders: putHeaders)
    }
}
