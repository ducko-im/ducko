import Foundation
import Testing
@testable import DuckoCore

// Pure-helper coverage for `BuildEnvironment`. The live static `let` properties read
// `ProcessInfo.processInfo` once and cache forever, which makes them resistant to in-process
// retesting; we test the underlying `compute*` helpers instead, exercising every documented
// branch (release, default-dev, profiled-dev) in both DEBUG and release configurations.

struct BuildEnvironmentTests {
    @Test func `release build uses production folder regardless of profile`() {
        #expect(BuildEnvironment.computeAppSupportDirectoryName(profile: nil, isDebug: false) == "Ducko")
        #expect(BuildEnvironment.computeAppSupportDirectoryName(profile: "alice", isDebug: false) == "Ducko")
    }

    @Test func `debug default uses dev folder`() {
        #expect(BuildEnvironment.computeAppSupportDirectoryName(profile: nil, isDebug: true) == "Ducko-Dev")
    }

    @Test func `debug with profile suffixes the dev folder`() {
        #expect(BuildEnvironment.computeAppSupportDirectoryName(profile: "alice", isDebug: true) == "Ducko-Dev-alice")
        #expect(BuildEnvironment.computeAppSupportDirectoryName(profile: "bob", isDebug: true) == "Ducko-Dev-bob")
    }

    @Test func `release build uses standard UserDefaults`() {
        #expect(BuildEnvironment.computeUserDefaultsSuiteName(profile: nil, isDebug: false) == nil)
        #expect(BuildEnvironment.computeUserDefaultsSuiteName(profile: "alice", isDebug: false) == nil)
    }

    @Test func `debug default uses dev UserDefaults suite`() {
        #expect(BuildEnvironment.computeUserDefaultsSuiteName(profile: nil, isDebug: true) == "im.ducko.dev")
    }

    @Test func `debug with profile suffixes the UserDefaults suite`() {
        #expect(BuildEnvironment.computeUserDefaultsSuiteName(profile: "alice", isDebug: true) == "im.ducko.dev.alice")
    }

    @Test func `release build offers direct Jingle candidates regardless of the proxy-only value`() {
        #expect(BuildEnvironment.computeJingleOffersDirectCandidates(proxyOnly: nil, isDebug: false))
        #expect(BuildEnvironment.computeJingleOffersDirectCandidates(proxyOnly: "1", isDebug: false))
    }

    @Test func `debug build withholds direct Jingle candidates only when proxy-only is 1`() {
        #expect(BuildEnvironment.computeJingleOffersDirectCandidates(proxyOnly: nil, isDebug: true))
        #expect(BuildEnvironment.computeJingleOffersDirectCandidates(proxyOnly: "0", isDebug: true))
        #expect(!BuildEnvironment.computeJingleOffersDirectCandidates(proxyOnly: "1", isDebug: true))
    }

    @Test func `live properties match the build configuration`() {
        // On a debug build the live properties should resolve to the dev path; on a release
        // build they should resolve to the production path. Either way they must agree with
        // the helper that produced them.
        #if DEBUG
            #expect(BuildEnvironment.appSupportDirectoryName.hasPrefix("Ducko-Dev"))
            #expect(BuildEnvironment.userDefaultsSuiteName?.hasPrefix("im.ducko.dev") == true)
        #else
            #expect(BuildEnvironment.appSupportDirectoryName == "Ducko")
            #expect(BuildEnvironment.userDefaultsSuiteName == nil)
        #endif
    }
}
