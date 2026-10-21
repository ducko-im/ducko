import DuckoXMPP
import Foundation

/// Re-export for DuckoUI which cannot import DuckoXMPP.
public typealias RoomFlag = DuckoXMPP.RoomFlag

public enum RoomRole: String, Sendable, Hashable {
    case moderator, participant, visitor, none
}

public enum RoomAffiliation: String, Sendable, Hashable {
    case owner, admin, member, outcast, none

    public var displayName: String {
        switch self {
        case .owner: "Owner"
        case .admin: "Admin"
        case .member: "Member"
        case .outcast: "Outcast"
        case .none: "Other"
        }
    }

    public var sortPriority: Int {
        switch self {
        case .owner: 0
        case .admin: 1
        case .member: 2
        case .none: 3
        case .outcast: 4
        }
    }
}

public struct RoomParticipant: Sendable, Identifiable, Hashable {
    public var id: String {
        nickname
    }

    public let nickname: String
    public let jidString: String?
    public let affiliation: RoomAffiliation
    public let role: RoomRole

    public init(nickname: String, jidString: String? = nil, affiliation: RoomAffiliation, role: RoomRole) {
        self.nickname = nickname
        self.jidString = jidString
        self.affiliation = affiliation
        self.role = role
    }
}

public struct RoomParticipantGroup: Sendable, Identifiable {
    public var id: RoomAffiliation {
        affiliation
    }

    public let affiliation: RoomAffiliation
    public let participants: [RoomParticipant]

    public init(affiliation: RoomAffiliation, participants: [RoomParticipant]) {
        self.affiliation = affiliation
        self.participants = participants
    }
}

public struct DiscoveredRoom: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let name: String?

    public init(jidString: String, name: String?) {
        self.jidString = jidString
        self.name = name
    }
}

public struct ChannelSearchResult: Sendable {
    public let channels: [SearchedChannel]
    public let hasMore: Bool
    public let lastCursor: String?

    public init(channels: [SearchedChannel], hasMore: Bool, lastCursor: String?) {
        self.channels = channels
        self.hasMore = hasMore
        self.lastCursor = lastCursor
    }
}

/// Bridge type for XEP-0433 channel search results — DuckoUI-safe (String JIDs).
public struct SearchedChannel: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let name: String?
    public let userCount: Int?
    public let isOpen: Bool?
    public let description: String?

    public init(jidString: String, name: String?, userCount: Int?, isOpen: Bool?, description: String?) {
        self.jidString = jidString
        self.name = name
        self.userCount = userCount
        self.isOpen = isOpen
        self.description = description
    }
}

/// Bridge type for `DataForm` so DuckoUI can show a form's title and instructions without importing DuckoXMPP.
public struct DataFormInfo: Sendable {
    public let title: String?
    public let instructions: [String]
    public var fields: [RoomConfigField]

    /// Whether every required field the user can edit has a value.
    public var hasRequiredValues: Bool {
        !fields.contains(where: \.isMissingRequiredValue)
    }

    public init(title: String? = nil, instructions: [String] = [], fields: [RoomConfigField] = []) {
        self.title = title
        self.instructions = instructions
        self.fields = fields
    }
}

/// Bridge type for `DataFormField` so DuckoUI can edit room config without importing DuckoXMPP.
public struct RoomConfigField: Sendable, Identifiable {
    /// Keys a field by its `var`, or by its position in the form for a fixed field without one.
    public enum FieldID: Hashable, Sendable {
        case variable(String)
        case position(Int)
    }

    public let id: FieldID
    public let variable: String?
    public let type: String?
    public let label: String?
    public let description: String?
    public let isRequired: Bool
    public var values: [String]
    public let options: [(label: String?, value: String)]

    /// Whether the user can edit this field (excludes FORM_TYPE, hidden and fixed fields).
    public var isUserEditable: Bool {
        variable != "FORM_TYPE" && type != "hidden" && !isFixed
    }

    /// Whether this field is text the form shows between its fields rather than a value to fill in.
    public var isFixed: Bool {
        type == "fixed"
    }

    public var isDisplayed: Bool {
        isUserEditable || isFixed
    }

    /// Whether this field is required and the user has not given it a value yet.
    public var isMissingRequiredValue: Bool {
        isRequired && isUserEditable && values.allSatisfy(\.isBlank)
    }

    /// User-facing label, falling back to the variable name.
    public var displayLabel: String {
        label ?? variable ?? ""
    }

    public init(
        variable: String?,
        position: Int = 0,
        type: String? = nil,
        label: String? = nil,
        description: String? = nil,
        isRequired: Bool = false,
        values: [String] = [],
        options: [(label: String?, value: String)] = []
    ) {
        self.id = variable.map(FieldID.variable) ?? .position(position)
        self.variable = variable
        self.type = type
        self.label = label
        self.description = description
        self.isRequired = isRequired
        // A boolean without a value is false (XEP-0004 §3.3), so a required one holds that value rather than none.
        self.values = type == "boolean" && isRequired && values.allSatisfy(\.isBlank) ? ["0"] : values
        self.options = options
    }

    /// Selects or deselects one option of a list field, keeping the selected values in the order the form lists them.
    public mutating func setOption(_ value: String, isSelected: Bool) {
        var selected = Set(values)
        if isSelected {
            selected.insert(value)
        } else {
            selected.remove(value)
        }
        values = optionValues(selected)
    }

    /// The option values among `selected`, in the order the form lists its options.
    public func optionValues(_ selected: Set<String>) -> [String] {
        options.map(\.value).filter(selected.contains)
    }
}

/// Bridge type for `MUCAffiliationItem` so DuckoUI can manage affiliations without importing DuckoXMPP.
public struct RoomAffiliationItem: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let affiliation: RoomAffiliation
    public let nickname: String?
    public let reason: String?

    public init(jidString: String, affiliation: RoomAffiliation, nickname: String? = nil, reason: String? = nil) {
        self.jidString = jidString
        self.affiliation = affiliation
        self.nickname = nickname
        self.reason = reason
    }
}

public struct PendingRoomInvite: Sendable, Identifiable {
    public var id: String {
        accountID.uuidString + "|" + roomJIDString + "|" + (fromJIDString ?? "")
    }

    public let accountID: UUID
    public let roomJIDString: String
    public let fromJIDString: String?
    public let reason: String?
    public let password: String?
    public let isDirect: Bool

    public init(accountID: UUID, roomJIDString: String, fromJIDString: String?, reason: String?, password: String?, isDirect: Bool = false) {
        self.accountID = accountID
        self.roomJIDString = roomJIDString
        self.fromJIDString = fromJIDString
        self.reason = reason
        self.password = password
        self.isDirect = isDirect
    }
}
