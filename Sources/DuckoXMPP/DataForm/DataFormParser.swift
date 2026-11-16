/// A `jabber:x:data` form per XEP-0004.
public struct DataForm: Sendable {
    public let title: String?
    public let instructions: [String]
    public var fields: [DataFormField]

    public init(title: String? = nil, instructions: [String] = [], fields: [DataFormField] = []) {
        self.title = title
        self.instructions = instructions
        self.fields = fields
    }
}

/// A single field in a `jabber:x:data` form per XEP-0004.
public struct DataFormField: Sendable {
    /// The field's `var`, which XEP-0004 lets only fixed fields omit.
    public let variable: String?
    public let type: String?
    public let label: String?
    public let description: String?
    public let isRequired: Bool
    public var values: [String]
    public let options: [(label: String?, value: String)]
    /// The URIs of the field's XEP-0221 media, in document order.
    public let media: [DataFormMediaURI]

    public init(
        variable: String?,
        type: String? = nil,
        label: String? = nil,
        description: String? = nil,
        isRequired: Bool = false,
        values: [String] = [],
        options: [(label: String?, value: String)] = [],
        media: [DataFormMediaURI] = []
    ) {
        self.variable = variable
        self.type = type
        self.label = label
        self.description = description
        self.isRequired = isRequired
        self.values = values
        self.options = options
        self.media = media
    }

    /// XEP-0004 §3.2 FORM_TYPE header for a `pubsub#publish-options` submit form.
    ///
    /// Prosody and other servers silently drop the entire publish-options form
    /// when this header is missing, leaving PEP nodes with default access
    /// instead of the publisher's requested configuration.
    public static let pubsubPublishOptionsHeader = DataFormField(
        variable: "FORM_TYPE",
        type: "hidden",
        values: [XMPPNamespaces.pubsubPublishOptions]
    )
}

/// One `<uri>` of a data form field's XEP-0221 media: where the media is, and its MIME type.
public struct DataFormMediaURI: Sendable, Equatable {
    public let type: String
    public let uri: String

    public init(type: String, uri: String) {
        self.type = type
        self.uri = uri
    }
}

/// Parses a `<x xmlns='jabber:x:data'>` element into a ``DataForm``.
func parseDataForm(_ element: XMLElement) -> DataForm {
    guard element.name == "x",
          element.namespace == XMPPNamespaces.dataForms else { return DataForm() }

    let fields = element.children(named: "field").map { field in
        let options: [(label: String?, value: String)] = field.children(named: "option").compactMap { option in
            guard let value = option.child(named: "value")?.textContent else { return nil }
            return (label: option.attribute("label"), value: value)
        }

        return DataFormField(
            variable: field.attribute("var"),
            type: field.attribute("type"),
            label: field.attribute("label"),
            description: field.childText(named: "desc"),
            isRequired: field.child(named: "required") != nil,
            values: field.children(named: "value").compactMap(\.textContent),
            options: options,
            media: parseMediaURIs(of: field)
        )
    }

    return DataForm(
        title: element.childText(named: "title"),
        instructions: element.children(named: "instructions").compactMap(\.textContent),
        fields: fields
    )
}

/// The URIs of every XEP-0221 `<media>` child of a field, skipping a `<uri>` without a type or text.
private func parseMediaURIs(of field: XMLElement) -> [DataFormMediaURI] {
    field.children(named: "media")
        .filter { $0.namespace == XMPPNamespaces.mediaElement }
        .flatMap { $0.children(named: "uri") }
        .compactMap { uri in
            guard let type = uri.attribute("type"), let text = uri.textContent else { return nil }
            var trimmed = String(text.drop(while: \.isWhitespace))
            while trimmed.last?.isWhitespace == true {
                trimmed.removeLast()
            }
            return trimmed.isEmpty ? nil : DataFormMediaURI(type: type, uri: trimmed)
        }
}

/// Builds a `<x type='submit'>` element from an array of ``DataFormField``,
/// leaving out fixed fields and fields without a `var`.
func buildSubmitForm(_ fields: [DataFormField]) -> XMLElement {
    var form = XMLElement(name: "x", namespace: XMPPNamespaces.dataForms, attributes: ["type": "submit"])

    for field in fields where field.type != "fixed" {
        guard let variable = field.variable else { continue }
        var attributes = ["var": variable]
        if let type = field.type { attributes["type"] = type }
        var fieldElement = XMLElement(name: "field", attributes: attributes)
        for value in field.values {
            var valueElement = XMLElement(name: "value")
            valueElement.addText(value)
            fieldElement.addChild(valueElement)
        }
        form.addChild(fieldElement)
    }

    return form
}
