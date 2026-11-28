import Darwin

/// Readable text for a POSIX `errno` value, e.g. "Connection refused" for `ECONNREFUSED`.
func posixErrorText(_ code: Int32) -> String {
    String(cString: strerror(code))
}

/// Readable reason for a failed address lookup, from its `getaddrinfo` result code.
func addressLookupFailureText(_ code: Int32) -> String {
    switch code {
    case EAI_NONAME, EAI_NODATA: "The address could not be found"
    case EAI_AGAIN: "The address lookup failed temporarily"
    default: "The address lookup failed"
    }
}

/// The reason for each connect errno, most concrete first.
private let connectFailurePhrases: [(codes: Set<Int32>, text: String)] = [
    ([ECONNREFUSED], "The connection was refused"),
    ([ECONNRESET], "The connection was reset"),
    ([EACCES, EPERM], "Permission to connect was denied"),
    ([ETIMEDOUT], "The connection attempt timed out"),
    ([EHOSTUNREACH], "The destination could not be reached"),
    ([ENETUNREACH], "The network could not be reached")
]

/// Readable reason for a failed TCP connect, from the errno of each address tried. The most concrete cause wins, so a
/// refusal on one address is not hidden by an unreachable route on another.
func connectFailureText(errnoCodes: [Int32]) -> String {
    connectFailurePhrases.first { errnoCodes.contains(where: $0.codes.contains) }?.text ?? "The connection could not be opened"
}
