import DuckoXMPP

/// The `<query/>` of a disco#info answer that lists `features`.
public func discoInfoQuery(features: Set<String>) -> XMLElement {
    var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
    for feature in features.sorted() {
        query.addChild(XMLElement(name: "feature", attributes: ["var": feature]))
    }
    return query
}
