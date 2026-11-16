import Darwin

/// The signals that end the CLI which it traps to clean up first: Ctrl-C, a kill, and the terminal closing. A signal
/// already ignored when this runs, as under `nohup`, is left out and stays ignored, so such a command survives the
/// terminal closing.
func trappableTerminatingSignals() -> [Int32] {
    [SIGINT, SIGTERM, SIGHUP].filter { !isIgnored($0) }
}

private func isIgnored(_ signo: Int32) -> Bool {
    var action = sigaction()
    guard sigaction(signo, nil, &action) == 0 else { return false }
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
}
