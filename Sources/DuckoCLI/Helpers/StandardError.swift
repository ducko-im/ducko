import Foundation

/// Prompts and guidance meant for the person at the terminal go to standard error, so stdout carries only formatted
/// command and event output. A write that fails, as on a terminal that has hung up, is dropped instead of ending the
/// process.
func printToStandardError(_ message: String, terminator: String = "\n") {
    try? FileHandle.standardError.write(contentsOf: Data((message + terminator).utf8))
}
