import Foundation

// Writes or removes the account data the Welcome window's Import mode discovers, for a run in the Lume VM only, since
// it writes the current user's real Application Support and defaults.
// Usage: swift ducko-import-seed.swift seed PROFILE ACCOUNT...
//        swift ducko-import-seed.swift clean PROFILE
//   ACCOUNT: UID, or UID,SERVER,PORT to give the account a connect server

func fail(_ message: String) -> Never {
    try? FileHandle.standardError.write(contentsOf: Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func runsInVM() -> Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
}

// The volume is case-insensitive, so UITEST names the uitest profile's folder as well.
func isFreshProfileName(_ name: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    return !name.isEmpty && name != "." && name != ".." && name.lowercased() != "uitest"
        && name.allSatisfy { allowed.contains($0) }
}

struct SeedAccount {
    let uid: String
    let server: String?
    let port: Int?

    init(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 3, !parts[0].isEmpty else {
            fail("an account is UID or UID,SERVER,PORT (got \(argument))")
        }
        uid = parts[0]
        guard parts.count == 3 else {
            server = nil
            port = nil
            return
        }
        // Discovery drops an empty or all-digit server, and sign-in converts the port with UInt16(port), which traps above 65535.
        guard !parts[1].isEmpty, !parts[1].allSatisfy(\.isNumber) else { fail("SERVER must be a host name (got \(parts[1]))") }
        guard let number = Int(parts[2]), (1 ... 65535).contains(number) else { fail("PORT must be 1...65535 (got \(parts[2]))") }
        server = parts[1]
        port = number
    }
}

// Every check of the arguments comes before the VM check. With DUCKO_IMPORT_SEED_CHECK_ONLY=1 the helper stops after
// them, so a test can run them on any host, a VM included, without reaching the data folders.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, ["seed", "clean"].contains(arguments[0]) else {
    fail("usage: ducko-import-seed.swift seed PROFILE ACCOUNT... | clean PROFILE")
}
let profile = arguments[1]
guard isFreshProfileName(profile) else {
    fail("PROFILE must be a fresh profile name of its own, not uitest (got \(profile))")
}
let isClean = arguments[0] == "clean"
guard isClean ? arguments.count == 2 : arguments.count > 2 else {
    fail(isClean ? "usage: ducko-import-seed.swift clean PROFILE" : "usage: ducko-import-seed.swift seed PROFILE ACCOUNT...")
}
let accounts = arguments.dropFirst(2).map(SeedAccount.init(argument:))
if ProcessInfo.processInfo.environment["DUCKO_IMPORT_SEED_CHECK_ONLY"] == "1" {
    print("arguments accepted")
    exit(0)
}
guard runsInVM() else {
    fail("this helper writes the current user's real data folders, so it runs only in the Lume VM (zsh Skills/lume-vm/scripts/vm.sh ui ducko-import-account.sh)")
}

let fileManager = FileManager.default
let support = fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
let seedFolder = support.appending(path: "Adium 2.0")
let profileFolder = support.appending(path: "Ducko-Dev-\(profile)")
let defaultsDomain = "im.ducko.dev.\(profile)"

if isClean {
    for folder in [seedFolder, profileFolder] where fileManager.fileExists(atPath: folder.path) {
        do {
            try fileManager.removeItem(at: folder)
        } catch {
            fail("could not remove \(folder.path): \(error.localizedDescription)")
        }
    }
    // When the app has run under the profile, the preferences daemon keeps an empty property list for the removed domain,
    // which `defaults read` shows as {}.
    UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
    print("Removed the seeded Adium 2.0 folder, \(profileFolder.lastPathComponent) and the \(defaultsDomain) defaults")
    exit(0)
}

// Everything clean removes later is then something this run created.
guard !fileManager.fileExists(atPath: profileFolder.path) else {
    fail("\(profileFolder.path) exists; an account there would skip the Welcome window, so use a fresh profile")
}
// An empty domain is what clean leaves behind, and holds nothing clean could lose.
guard UserDefaults.standard.persistentDomain(forName: defaultsDomain)?.isEmpty ?? true else {
    fail("the \(defaultsDomain) defaults hold values and clean would erase them, so use a fresh profile")
}
guard !fileManager.fileExists(atPath: seedFolder.path) else {
    fail("\(seedFolder.path) exists and clean would erase it")
}

var accountList: [[String: String]] = []
var accountPrefs: [String: [String: Any]] = [:]
for (index, account) in accounts.enumerated() {
    let objectID = String(index + 1)
    accountList.append(["ObjectID": objectID, "Service": "Jabber", "UID": account.uid])
    if let server = account.server, let port = account.port {
        accountPrefs[objectID] = ["Jabber:Connect Server": server, "Connect Port": port]
    }
}

let userFolder = seedFolder.appending(path: "Users/Default")
do {
    try fileManager.createDirectory(at: userFolder, withIntermediateDirectories: true)
    let accountsData = try PropertyListSerialization.data(fromPropertyList: ["Accounts": accountList], format: .xml, options: 0)
    try accountsData.write(to: userFolder.appending(path: "Accounts.plist"))
    let prefsData = try PropertyListSerialization.data(fromPropertyList: accountPrefs, format: .xml, options: 0)
    try prefsData.write(to: userFolder.appending(path: "AccountPrefs.plist"))
} catch {
    // The folder did not exist before this run, so removing it lets a retry start clean.
    try? fileManager.removeItem(at: seedFolder)
    fail("could not write the account data: \(error.localizedDescription)")
}

for (index, account) in accounts.enumerated() {
    print("\(index + 1) \(account.uid)")
}
