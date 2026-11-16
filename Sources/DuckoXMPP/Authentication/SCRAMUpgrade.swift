extension SCRAMHash {
    /// The SASL2 task that upgrades the server's stored credential to this hash (XEP-0480 §2.1). Its name never
    /// carries `-PLUS`.
    var upgradeTaskName: String {
        "UPGR-" + mechanismName
    }
}

/// The hash to ask the server to upgrade to: the strongest offered one that is stronger than the selected mechanism's.
/// The SaltedPassword the upgrade sends is password-equivalent, so only a channel-bound sign-in asks for one
/// (XEP-0480 §5).
func selectSCRAMUpgrade(offered: Set<String>, selectedMechanism: String, channelBinding: ChannelBindingMode) -> SCRAMHash? {
    switch channelBinding {
    case .bound:
        break
    case .none, .clientSupportsButNotUsed:
        return nil
    }
    guard let selected = SCRAMHash(mechanism: selectedMechanism) else { return nil }
    return SCRAMHash.allCases.prefix { $0 != selected }.first { offered.contains($0.upgradeTaskName) }
}

/// The salt and iteration count of the server's `<task-data>` (XEP-0480 §3), or why they can't be used.
func parseSCRAMUpgradeSalt(_ taskData: XMLElement) -> Result<(salt: [UInt8], iterations: Int), SASLAuthError> {
    guard let saltElement = taskData.child(named: "salt", namespace: XMPPNamespaces.scramUpgrade),
          let encoded = saltElement.textContent,
          let iterations = saltElement.attribute("iterations").flatMap({ Int($0) })
    else {
        return .failure(.malformedUpgradeTask)
    }
    guard iterations >= scramMinimumIterationCount else {
        return .failure(.iterationCountTooLow(iterations))
    }
    guard let salt = Base64.decode(encoded) else {
        return .failure(.invalidBase64)
    }
    guard !salt.isEmpty else {
        return .failure(.malformedUpgradeTask)
    }
    return .success((salt, iterations))
}

/// The `<task-data>` that returns the SaltedPassword for the upgraded hash (XEP-0480 §3).
func scramUpgradeHashElement(_ saltedPassword: [UInt8]) -> XMLElement {
    var hash = XMLElement(name: "hash", namespace: XMPPNamespaces.scramUpgrade)
    hash.addText(Base64.encode(saltedPassword))
    var taskData = XMLElement(name: "task-data", namespace: XMPPNamespaces.sasl2)
    taskData.addChild(hash)
    return taskData
}
