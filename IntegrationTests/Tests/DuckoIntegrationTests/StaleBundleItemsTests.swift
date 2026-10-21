import DuckoXMPP
import Testing

/// Deterministic tests for `ResetTestServerState.staleBundleItemIDs(in:keeping:)`.
/// The live reset suite only exercises whatever state the server happens to
/// have, so it can't prove the predicate keeps the live bundle.
///
/// Declared as a top-level `enum` so the suite does not inherit
/// `DuckoIntegrationTests`'s `.enabled(if: TestCredentials.isAvailable)`
/// trait — the predicate has no live-server dependency and must run on any
/// developer or CI environment.
enum StaleBundleItemsTests {
    struct Filtering {
        private let liveDeviceID = "4242"

        @Test func `stale bundles are reported, live bundle is preserved`() {
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleItemIDs(
                in: [bundleItem("1"), bundleItem(liveDeviceID), bundleItem("99")],
                keeping: liveDeviceID
            )
            #expect(stale == ["1", "99"])
        }

        @Test func `a second pass over the post-sweep state yields no stale bundles`() {
            let stale = DuckoIntegrationTests.ResetTestServerState.staleBundleItemIDs(
                in: [bundleItem(liveDeviceID)],
                keeping: liveDeviceID
            )
            #expect(stale.isEmpty)
        }

        private func bundleItem(_ deviceID: String) -> PEPItem {
            PEPItem(id: deviceID, payload: XMLElement(name: "bundle", namespace: XMPPNamespaces.omemo))
        }
    }
}
