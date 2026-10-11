import CoreGraphics
import Foundation

// Prints the number of the first on-screen window owned by the PID at the normal window layer.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fail("Expected a process ID", code: 2)
}
// The window server refuses the listing from inside the Bash sandbox.
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    fail("Window list unavailable: run outside the sandbox")
}
guard let window = windows.first(where: {
    $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0
}), let number = window[kCGWindowNumber as String] as? Int else {
    fail("No window found for process \(pid)")
}
print(number)
