/// A disco#info reply as the caps hashes read it. ``ServiceDiscoveryModule/InfoResult`` drops duplicate features, which
/// XEP-0115 §5.4 counts as an ill-formed reply.
struct CapsDiscoInfo {
    /// What a caps hash covers.
    struct HashInput {
        let identities: [ServiceDiscoveryModule.Identity]
        let features: Set<String>
        let forms: [[DataFormField]]
    }

    private let query: XMLElement
    private let iqLang: String?
    private let streamLang: String?

    /// `streamLang` is the `xml:lang` of the stream `reply` came on.
    init?(_ reply: XMPPIQ, streamLang: String? = nil) {
        guard let query = reply.childElement, query.name == "query", query.namespace == XMPPNamespaces.discoInfo else {
            return nil
        }
        self.query = query
        self.iqLang = reply.element.attribute("xml:lang")
        self.streamLang = streamLang
    }

    /// Every feature the reply lists, duplicates included.
    var features: [String] {
        query.children(named: "feature").compactMap { $0.attribute("var") }
    }

    private var dataForms: [XMLElement] {
        query.children(named: "x").filter { $0.namespace == XMPPNamespaces.dataForms }
    }

    /// The XEP-0115 §5.4 hash input, or `nil` when the reply is ill-formed: a repeated identity or feature, two forms of
    /// one FORM_TYPE, or a FORM_TYPE with differing values. Forms whose FORM_TYPE is missing or not hidden are left out.
    var capsInput: HashInput? {
        let identities = query.children(named: "identity").map { identity(from: $0, lang: $0.attribute("xml:lang")) }
        guard Set(identities).count == identities.count else { return nil }
        let features = features
        let featureSet = Set(features)
        guard featureSet.count == features.count else { return nil }

        var formTypes: Set<String> = []
        var hashedForms: [[DataFormField]] = []
        for fields in dataForms.map(hashedFields(of:)) {
            guard let formTypeField = fields.first(where: { $0.variable == "FORM_TYPE" }) else { continue }
            let values = Set(formTypeField.values)
            guard values.count <= 1 else { return nil }
            guard let formType = values.first else { continue }
            guard formTypes.insert(formType).inserted else { return nil }
            if formTypeField.type == "hidden" {
                hashedForms.append(fields)
            }
        }
        return HashInput(identities: identities, features: featureSet, forms: hashedForms)
    }

    /// The XEP-0390 §4.1 hash input, or `nil` when the hash cannot be computed. That is the case when the query holds
    /// an element other than identities, features and data forms, or when a form has `<reported/>`, `<item/>` or no
    /// FORM_TYPE. An identity without `xml:lang` inherits the query's, else the `<iq>`'s, else the stream's (§4.1).
    /// The sender's server stamps its stream's language on an `<iq>` that has none (RFC 6120 §8.1.5).
    var caps2Input: HashInput? {
        for case let .element(child) in query.children {
            switch (child.name, child.namespace) {
            case ("identity", XMPPNamespaces.discoInfo), ("feature", XMPPNamespaces.discoInfo), ("x", XMPPNamespaces.dataForms):
                continue
            default:
                return nil
            }
        }
        var forms: [[DataFormField]] = []
        for form in dataForms {
            guard form.child(named: "reported") == nil, form.child(named: "item") == nil else { return nil }
            let fields = hashedFields(of: form)
            guard fields.contains(where: { $0.variable == "FORM_TYPE" }) else { return nil }
            forms.append(fields)
        }
        let inheritedLang = query.attribute("xml:lang") ?? iqLang ?? streamLang
        let identities = query.children(named: "identity").map { identity(from: $0, lang: $0.attribute("xml:lang") ?? inheritedLang) }
        return HashInput(identities: identities, features: Set(features), forms: forms)
    }

    /// The form's fields with every value they hold. `parseDataForm` leaves out an empty `<value/>`, which both hashes
    /// count as an empty string.
    private func hashedFields(of form: XMLElement) -> [DataFormField] {
        zip(parseDataForm(form).fields, form.children(named: "field")).map { field, element in
            var field = field
            field.values = element.children(named: "value").map { $0.textContent ?? "" }
            return field
        }
    }

    private func identity(from element: XMLElement, lang: String?) -> ServiceDiscoveryModule.Identity {
        ServiceDiscoveryModule.Identity(
            category: element.attribute("category") ?? "",
            type: element.attribute("type") ?? "",
            lang: lang ?? "",
            name: element.attribute("name")
        )
    }
}
