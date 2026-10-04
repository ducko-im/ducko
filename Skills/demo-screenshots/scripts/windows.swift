import AppKit

// Lists the windows of a PID, one per line:
//   <window number> layer <n> onscreen <true|false> x <x> y <y> w <width> h <height> title: <title>
// Usage: swift windows.swift <pid>
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: windows.swift <pid>, with exactly one PID\n".utf8))
    exit(2)
}
// The window server refuses the listing from inside the Bash sandbox.
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("window list unavailable: run outside the sandbox\n".utf8))
    exit(1)
}
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print(w[kCGWindowNumber as String] ?? "?", "layer", w[kCGWindowLayer as String] ?? "?", "onscreen", onscreen,
          "x", b["X"] ?? "?", "y", b["Y"] ?? "?", "w", b["Width"] ?? "?", "h", b["Height"] ?? "?",
          "title:", w[kCGWindowName as String] ?? "-")
}
