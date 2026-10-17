import DuckoCore

extension ChatMessage {
    /// What an incoming message's sender is called: their nickname in a room, else the name `contactName` gives
    /// them in the contact list.
    func incomingSenderName(contactName: String?) -> String {
        if type == "groupchat" {
            return fromJID
        }
        return contactName ?? fromJID
    }
}
