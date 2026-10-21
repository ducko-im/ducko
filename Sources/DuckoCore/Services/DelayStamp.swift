import DuckoXMPP
import Foundation

/// The time a live message was sent, from a delay (XEP-0203) a trusted party stamped on it: the account's own server,
/// which held the message while the account was offline, or the room a `groupchat` message comes from, which replays
/// its history on join. Anyone else's delay, and one that names no stamper, could put the message at any time and is
/// ignored. Carbons and archived messages carry the time in their wrapper instead.
package struct DelayStamp {
    /// When the message was sent, never later than it arrived.
    package let sentTime: Date
    /// Whether the room stamped it, as it does the history it replays on join.
    package let isFromRoom: Bool

    package init?(in message: XMPPMessage, accountJID: BareJID?, receivedAt: Date = Date()) {
        let server = accountJID.flatMap { BareJID(localPart: nil, domainPart: $0.domainPart) }
        let room = message.messageType == .groupchat ? message.from?.bareJID : nil
        let delays = message.element.children(named: "delay").filter { $0.namespace == XMPPNamespaces.delay }
        for delay in delays {
            guard let from = delay.attribute("from").flatMap(BareJID.parse), from == server || from == room,
                  let stamp = delay.attribute("stamp").flatMap(Date.init(xmppTimestamp:)) else { continue }
            self.sentTime = min(stamp, receivedAt)
            self.isFromRoom = from == room
            return
        }
        return nil
    }
}

package extension Date {
    /// Reads an XEP-0082 timestamp, with or without fractional seconds.
    init?(xmppTimestamp stamp: String) {
        let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
            ?? (try? Date.ISO8601FormatStyle().parse(stamp))
        guard let parsed else { return nil }
        self = parsed
    }
}

package extension ForwardedMessage {
    /// When the forwarded message was sent: the time its wrapper's delay names, else now.
    var sentTime: Date {
        timestamp.flatMap(Date.init(xmppTimestamp:)) ?? Date()
    }
}
