import CDnssd
import Darwin

/// A DNS SRV record per RFC 2782.
struct SRVRecord: Comparable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    let target: String
    let directTLS: Bool

    /// A target of "." says the domain decidedly does not offer the service (RFC 2782).
    var isServiceNotOffered: Bool {
        target == "."
    }

    static func < (lhs: SRVRecord, rhs: SRVRecord) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        // Higher weight = more preferred within same priority
        return lhs.weight > rhs.weight
    }
}

/// DNS SRV resolution per RFC 6120 §3.2 and XEP-0368.
///
/// Resolves both `_xmpp-client._tcp.{domain}` (STARTTLS) and `_xmpps-client._tcp.{domain}`
/// (direct TLS) to get host/port records. Falls back to `domain:5222` when neither lookup returns a record. Returns no
/// record when every answer has a "." target, which says the service is not offered.
enum XMPPSRVLookup {
    static func resolve(domain: String, timeout: Duration = .seconds(5)) async -> [SRVRecord] {
        await withTaskGroup(of: [SRVRecord]?.self) { group in
            group.addTask {
                await (try? querySRV(domain: domain, directTLS: false)) ?? []
            }
            group.addTask {
                await (try? querySRV(domain: domain, directTLS: true)) ?? []
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // Timeout signal
            }

            var allRecords: [SRVRecord] = []
            var queryCount = 0
            for await result in group {
                guard let records = result else { break } // Timeout
                allRecords.append(contentsOf: records)
                queryCount += 1
                if queryCount >= 2 { break }
            }
            group.cancelAll()

            return connectionOrder(for: allRecords, domain: domain)
        }
    }

    /// Drops "." answers and sorts the rest. A "." answer also rules out the A/AAAA fallback (RFC 6120 §3.2.1,
    /// XEP-0368), since the domain has said it uses SRV.
    static func connectionOrder(for records: [SRVRecord], domain: String) -> [SRVRecord] {
        let usable = records.filter { !$0.isServiceNotOffered }
        if !usable.isEmpty {
            return usable.sorted()
        }
        if records.contains(where: \.isServiceNotOffered) {
            return []
        }
        return fallback(domain: domain)
    }

    private static func fallback(domain: String) -> [SRVRecord] {
        [SRVRecord(priority: 0, weight: 0, port: 5222, target: domain, directTLS: false)]
    }

    private static func querySRV(domain: String, directTLS: Bool) async throws -> [SRVRecord] {
        try await Task.detached {
            try srvQuery(domain: domain, directTLS: directTLS)
        }.value
    }
}

// MARK: - DNS SRV Query

private struct SRVQueryData {
    let directTLS: Bool
    var records: [SRVRecord] = []
    var isDone = false
}

/// Synchronous DNS SRV query using `poll()` + `DNSServiceProcessResult`.
///
/// Runs entirely on the calling thread — no async/callback nesting needed.
/// The DNS-SD callback fires synchronously during `DNSServiceProcessResult`.
private func srvQuery(domain: String, directTLS: Bool) throws -> [SRVRecord] {
    let prefix = directTLS ? "_xmpps-client._tcp" : "_xmpp-client._tcp"
    let name = "\(prefix).\(domain)"
    var sdRef: DNSServiceRef?

    let dataPtr = UnsafeMutablePointer<SRVQueryData>.allocate(capacity: 1)
    dataPtr.initialize(to: SRVQueryData(directTLS: directTLS))
    defer { dataPtr.deinitialize(count: 1); dataPtr.deallocate() }

    let callback: DNSServiceQueryRecordReply = {
        _, flags, _, errorCode, _, _, _, rdlen, rdata, _, ctx in
        guard let ctx else { return }
        let data = ctx.assumingMemoryBound(to: SRVQueryData.self)

        guard errorCode == kDNSServiceErr_NoError else {
            data.pointee.isDone = true
            return
        }

        if let record = srvParseSRVRecord(rdata, length: rdlen, directTLS: data.pointee.directTLS) {
            data.pointee.records.append(record)
        }

        if flags & kDNSServiceFlagsMoreComing == 0 {
            data.pointee.isDone = true
        }
    }

    let err = DNSServiceQueryRecord(
        &sdRef,
        kDNSServiceFlagsReturnIntermediates,
        0,
        name,
        UInt16(kDNSServiceType_SRV),
        UInt16(kDNSServiceClass_IN),
        callback,
        dataPtr
    )

    guard err == kDNSServiceErr_NoError, let sdRef else {
        throw XMPPClientError.connectionFailed("The DNS lookup could not start")
    }
    defer { DNSServiceRefDeallocate(sdRef) }

    let fd = DNSServiceRefSockFD(sdRef)
    guard fd >= 0 else {
        throw XMPPClientError.connectionFailed("The DNS lookup could not start")
    }

    // Process results synchronously with poll(), 100ms per iteration, 5s max
    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    for _ in 0 ..< 50 {
        if dataPtr.pointee.isDone { break }
        let result = Darwin.poll(&pollFd, 1, 100)
        if result < 0 { break }
        if result > 0 {
            DNSServiceProcessResult(sdRef)
        }
    }

    return dataPtr.pointee.records
}

/// Parses a single SRV record from DNS rdata, or `nil` if the rdata is too short or its target name is cut off. The root
/// target parses as ".".
private func srvParseSRVRecord(_ rdata: UnsafeRawPointer?, length: UInt16, directTLS: Bool) -> SRVRecord? {
    guard let rdata, length >= 7 else { return nil }
    let ptr = rdata.assumingMemoryBound(to: UInt8.self)
    let priority = UInt16(ptr[0]) << 8 | UInt16(ptr[1])
    let weight = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
    let port = UInt16(ptr[4]) << 8 | UInt16(ptr[5])
    guard let name = srvParseDNSName(ptr + 6, length: Int(length) - 6) else { return nil }
    return SRVRecord(priority: priority, weight: weight, port: port, target: name.isEmpty ? "." : name, directTLS: directTLS)
}

/// Parses a DNS wire-format name (sequence of length-prefixed labels) into a dotted string, empty for the root name, or
/// `nil` when a label runs past `length`.
private func srvParseDNSName(_ ptr: UnsafePointer<UInt8>, length: Int) -> String? {
    var labels: [String] = []
    var offset = 0
    while offset < length {
        let labelLength = Int(ptr[offset])
        if labelLength == 0 { return labels.joined(separator: ".") }
        offset += 1
        guard offset + labelLength <= length else { return nil }
        let label = String(
            decoding: UnsafeBufferPointer(start: ptr + offset, count: labelLength),
            as: UTF8.self
        )
        labels.append(label)
        offset += labelLength
    }
    return labels.joined(separator: ".")
}
