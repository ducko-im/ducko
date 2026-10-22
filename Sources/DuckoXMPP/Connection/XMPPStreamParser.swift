import CLibxml2

/// Incremental XML stream parser for XMPP using libxml2 SAX2 push parsing.
///
/// Feed raw bytes via ``parse(_:)`` and collect returned events synchronously.
/// The parser tracks element depth to handle the XMPP stream lifecycle:
/// depth 0→1 emits ``XMLStreamEvent/streamOpened(attributes:)``,
/// depth 2→1 emits ``XMLStreamEvent/stanzaReceived(_:)``,
/// and depth 1→0 emits ``XMLStreamEvent/streamClosed``.
final class XMPPStreamParser {
    private var parserCtxt: xmlParserCtxtPtr?
    private var depth = 0
    /// The open elements below the stream, each with the namespace libxml2 resolved for it.
    private var elementStack: [(element: XMLElement, namespaceURI: String?)] = []
    private var contentNamespace: String?
    private var hasError = false
    private var isClosing = false
    private var pendingEvents: [XMLStreamEvent] = []

    init() {
        var sax = xmlSAXHandler()
        sax.initialized = XML_SAX2_MAGIC
        sax.startElementNs = saxStartElementNs
        sax.endElementNs = saxEndElementNs
        sax.characters = saxCharacters
        sax.serror = saxStructuredError

        let userData = Unmanaged.passUnretained(self).toOpaque()
        self.parserCtxt = xmlCreatePushParserCtxt(&sax, userData, nil, 0, nil)
    }

    deinit {
        if let ctx = parserCtxt {
            if let doc = ctx.pointee.myDoc {
                xmlFreeDoc(doc)
            }
            xmlFreeParserCtxt(ctx)
        }
    }

    // MARK: - Feeding Data

    /// Feed raw bytes into the parser. SAX callbacks fire synchronously and events are returned.
    @discardableResult
    func parse(_ bytes: [UInt8]) -> [XMLStreamEvent] {
        guard !hasError, let ctx = parserCtxt, !bytes.isEmpty else { return [] }
        pendingEvents = []
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { ptr in
                _ = xmlParseChunk(ctx, ptr, Int32(buffer.count), 0)
            }
        }
        return pendingEvents
    }

    /// Terminates the parser and returns any final events.
    @discardableResult
    func close() -> [XMLStreamEvent] {
        isClosing = true
        pendingEvents = []
        if let ctx = parserCtxt {
            _ = xmlParseChunk(ctx, nil, 0, 1)
        }
        return pendingEvents
    }

    // MARK: - SAX Callback Handlers

    fileprivate func handleStartElement(
        localname: String,
        namespaceURI: String?,
        namespaceDeclarations: [(prefix: String?, uri: String)],
        attributes: [String: String]
    ) {
        depth += 1
        if depth == 1 {
            // <stream:stream> opened — track content namespace and emit event
            for (prefix, uri) in namespaceDeclarations where prefix == nil {
                contentNamespace = uri
            }
            var allAttrs = attributes
            for (nsPrefix, nsURI) in namespaceDeclarations {
                if let nsPrefix {
                    allAttrs["xmlns:\(nsPrefix)"] = nsURI
                } else {
                    allAttrs["xmlns"] = nsURI
                }
            }
            pendingEvents.append(.streamOpened(attributes: allAttrs))
        } else {
            let element = XMLElement(name: localname, namespace: storedNamespace(of: namespaceURI), attributes: attributes)
            elementStack.append((element, namespaceURI))
        }
    }

    /// The content namespace is left implicit, so stanzas and their children read as unqualified. Below an element in
    /// another namespace, an element back in the content namespace or in none keeps that namespace explicitly (`""` for
    /// none), so writing it out again does not put it in its parent's namespace.
    private func storedNamespace(of namespaceURI: String?) -> String? {
        let isContentOrNone = namespaceURI == nil || namespaceURI == contentNamespace
        if isContentOrNone, let parent = elementStack.last, parent.namespaceURI != namespaceURI {
            return namespaceURI ?? ""
        }
        return namespaceURI == contentNamespace ? nil : namespaceURI
    }

    fileprivate func handleEndElement() {
        switch depth {
        case 1:
            pendingEvents.append(.streamClosed)
        case 2:
            if let stanza = elementStack.popLast()?.element {
                pendingEvents.append(.stanzaReceived(stanza))
            }
        default:
            if let child = elementStack.popLast()?.element {
                elementStack[elementStack.count - 1].element.addChild(child)
            }
        }
        depth -= 1
    }

    fileprivate func handleCharacters(_ text: String) {
        guard depth >= 2, !elementStack.isEmpty else { return }
        elementStack[elementStack.count - 1].element.addText(text)
    }

    fileprivate func handleError(_ message: String) {
        guard !isClosing else { return }
        hasError = true
        pendingEvents.append(.error(XMLStreamParseError(message: message)))
    }
}

// MARK: - SAX2 Callbacks

// periphery:ignore:parameters prefix,nb_defaulted
// swiftlint:disable:next function_parameter_count
private func saxStartElementNs(
    _ ctx: UnsafeMutableRawPointer?,
    _ localname: UnsafePointer<xmlChar>?,
    _ prefix: UnsafePointer<xmlChar>?,
    _ URI: UnsafePointer<xmlChar>?,
    _ nb_namespaces: Int32,
    _ namespaces: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?,
    _ nb_attributes: Int32,
    _ nb_defaulted: Int32,
    _ attributes: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?
) {
    guard let ctx, let localname else { return }
    let parser = Unmanaged<XMPPStreamParser>.fromOpaque(ctx).takeUnretainedValue()

    let name = String(cString: localname)
    let uri = URI.map { String(cString: $0) }

    // Extract namespace declarations (prefix/URI pairs)
    var nsDecls: [(prefix: String?, uri: String)] = []
    if let namespaces, nb_namespaces > 0 {
        for i in 0 ..< Int(nb_namespaces) {
            let base = i * 2
            let nsPrefix = namespaces[base].map { String(cString: $0) }
            let nsURI = namespaces[base + 1].map { String(cString: $0) } ?? ""
            nsDecls.append((prefix: nsPrefix, uri: nsURI))
        }
    }

    // Extract attributes from quintuplet array [localname, prefix, URI, valueBegin, valueEnd]
    var attrs: [String: String] = [:]
    if let attributes, nb_attributes > 0 {
        for i in 0 ..< Int(nb_attributes) {
            let base = i * 5
            guard let attrLocalname = attributes[base] else { continue }
            let key: String
            if let attrPrefix = attributes[base + 1] {
                let prefix = String(cString: attrPrefix)
                key = prefix + ":" + String(cString: attrLocalname)
                // Element names drop their prefix, but prefixed attributes keep theirs, so the element carries the
                // prefix's declaration and stays well-formed when written out on its own. The xml prefix needs no
                // declaration.
                if prefix != "xml", let attrURI = attributes[base + 2] {
                    attrs["xmlns:" + prefix] = String(cString: attrURI)
                }
            } else {
                key = String(cString: attrLocalname)
            }
            if let valueStart = attributes[base + 3], let valueEnd = attributes[base + 4] {
                let length = valueEnd - valueStart
                let value = String(
                    decoding: UnsafeBufferPointer(start: valueStart, count: length),
                    as: UTF8.self
                )
                attrs[key] = value
            }
        }
    }

    parser.handleStartElement(
        localname: name,
        namespaceURI: uri,
        namespaceDeclarations: nsDecls,
        attributes: attrs
    )
}

// periphery:ignore:parameters localname,prefix,URI
private func saxEndElementNs(
    _ ctx: UnsafeMutableRawPointer?,
    _ localname: UnsafePointer<xmlChar>?,
    _ prefix: UnsafePointer<xmlChar>?,
    _ URI: UnsafePointer<xmlChar>?
) {
    guard let ctx else { return }
    let parser = Unmanaged<XMPPStreamParser>.fromOpaque(ctx).takeUnretainedValue()
    parser.handleEndElement()
}

private func saxCharacters(
    _ ctx: UnsafeMutableRawPointer?,
    _ ch: UnsafePointer<xmlChar>?,
    _ len: Int32
) {
    guard let ctx, let ch else { return }
    let parser = Unmanaged<XMPPStreamParser>.fromOpaque(ctx).takeUnretainedValue()
    let text = String(decoding: UnsafeBufferPointer(start: ch, count: Int(len)), as: UTF8.self)
    parser.handleCharacters(text)
}

private func saxStructuredError(
    _ userData: UnsafeMutableRawPointer?,
    _ error: xmlErrorPtr?
) {
    guard let userData, let error else { return }
    let level = error.pointee.level
    guard level == XML_ERR_ERROR || level == XML_ERR_FATAL else { return }
    let parser = Unmanaged<XMPPStreamParser>.fromOpaque(userData).takeUnretainedValue()
    let message: String
    if let msgPtr = error.pointee.message {
        var msg = String(cString: msgPtr)
        while msg.last?.isWhitespace == true {
            msg.removeLast()
        }
        message = msg
    } else {
        message = "XML parse error"
    }
    parser.handleError(message)
}
