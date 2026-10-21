import Testing
@testable import DuckoUI

struct ChannelSearchCooldownTests {
    @Test
    func `The cooldown counts whole seconds down and ends when they elapse`() {
        let start = ContinuousClock.now
        let cooldown = ChannelSearchCooldown(seconds: 30, from: start)

        #expect(cooldown.remainingSeconds(at: start) == 30)
        #expect(cooldown.remainingSeconds(at: start + .milliseconds(500)) == 30)
        #expect(cooldown.remainingSeconds(at: start + .milliseconds(29500)) == 1)
        #expect(cooldown.remainingSeconds(at: start + .seconds(30)) == nil)
    }

    @Test
    func `The next change is when the shown second ticks over`() {
        let start = ContinuousClock.now
        let cooldown = ChannelSearchCooldown(seconds: 30, from: start)

        #expect(cooldown.nextChange(after: start + .milliseconds(500)) == start + .seconds(1))
        #expect(cooldown.nextChange(after: start + .milliseconds(29500)) == start + .seconds(30))
    }
}
