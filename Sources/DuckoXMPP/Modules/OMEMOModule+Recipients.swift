extension OMEMOModule.EncryptionBatch {
    /// The batch with each key whose device is off its owner's list in `deviceLists` moved to `dropped`, as a device
    /// without a bundle is. A JID with no list there is kept, since the caller has just fetched its list. The session of
    /// a dropped device has advanced by one message key, which its ratchet tolerates as a skipped key.
    func keepingDevices(listedIn deviceLists: [BareJID: [UInt32]]) -> Self {
        var batch = Self(results: [], dropped: dropped)
        for result in results {
            let key = result.sessionKey
            if let listed = deviceLists[key.jid], !listed.contains(key.deviceID) {
                batch.dropped.append(DroppedOMEMORecipient(jid: key.jid, deviceID: key.deviceID))
            } else {
                batch.results.append(result)
            }
        }
        return batch
    }
}
