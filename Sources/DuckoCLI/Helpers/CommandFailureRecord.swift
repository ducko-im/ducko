import ArgumentParser

/// The JSON `error` record for `error` thrown from the `run()` of `command`. It is nil when the command does not print
/// JSON. It is also nil for an `ExitCode`, which a command throws after printing its own failure, and for a
/// `CleanExit`, whose output ArgumentParser prints.
func commandFailureRecord(for error: any Error, command: any ParsableCommand) -> String? {
    guard !(error is ExitCode), !(error is CleanExit), globalOptionGroup(of: command)?.wrappedValue.resolvedFormat == .json else { return nil }
    return JSONFormatter().formatError(error)
}

/// The global options `command` holds as a direct `@OptionGroup` property. Reflection does not see one nested inside
/// another option group.
func globalOptionGroup(of command: any ParsableCommand) -> OptionGroup<GlobalOptions>? {
    Mirror(reflecting: command).children.lazy.compactMap { $0.value as? OptionGroup<GlobalOptions> }.first
}
