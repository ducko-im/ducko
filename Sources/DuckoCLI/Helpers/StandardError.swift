import Foundation

/// Writes a newline-terminated UTF-8 message to standard error. The session-scoped one-shot warning and the
/// informational hold/interrupt lines go here so stdout stays reserved for formatted command and event output. A write
/// that fails, as on a terminal that has hung up, is dropped instead of ending the process.
func printToStandardError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}
