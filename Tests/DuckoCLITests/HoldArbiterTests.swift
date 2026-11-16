import Darwin
import Testing
@testable import DuckoCLI

struct HoldArbiterTests {
    @Test func `first SIGINT yields interrupted and does not hard-exit`() async {
        let arbiter = HoldArbiter()
        let hardExit = await arbiter.recordSignal(SIGINT)
        #expect(hardExit == false)

        var iterator = arbiter.ends.makeAsyncIterator()
        guard case let .interrupted(signo)? = await iterator.next() else {
            Issue.record("expected .interrupted")
            return
        }
        #expect(signo == SIGINT)
    }

    @Test func `first SIGTERM carries the SIGTERM number`() async {
        let arbiter = HoldArbiter()
        _ = await arbiter.recordSignal(SIGTERM)

        var iterator = arbiter.ends.makeAsyncIterator()
        guard case let .interrupted(signo)? = await iterator.next() else {
            Issue.record("expected .interrupted")
            return
        }
        #expect(signo == SIGTERM)
    }

    @Test func `second signal forces a hard exit, third is ignored`() async {
        let arbiter = HoldArbiter()
        #expect(await arbiter.recordSignal(SIGINT) == false)
        #expect(await arbiter.recordSignal(SIGINT) == true)
        #expect(await arbiter.recordSignal(SIGINT) == false)
    }

    @Test func `natural expiry yields expired`() async {
        let arbiter = HoldArbiter()
        await arbiter.recordExpiry()

        var iterator = arbiter.ends.makeAsyncIterator()
        guard case .expired? = await iterator.next() else {
            Issue.record("expected .expired")
            return
        }
    }

    @Test func `work failure yields workFailed`() async {
        let arbiter = HoldArbiter()
        await arbiter.recordWorkFailed()

        var iterator = arbiter.ends.makeAsyncIterator()
        guard case .workFailed? = await iterator.next() else {
            Issue.record("expected .workFailed")
            return
        }
    }

    @Test func `a signal after expiry hard-exits`() async {
        let arbiter = HoldArbiter()
        await arbiter.recordExpiry()
        #expect(await arbiter.recordSignal(SIGINT) == true)
    }

    @Test func `a signal during begun teardown hard-exits`() async {
        let arbiter = HoldArbiter()
        await arbiter.beginTeardown()
        #expect(await arbiter.recordSignal(SIGTERM) == true)
    }

    @Test func `the repeat SIGHUP of a closing terminal lets teardown finish, and Ctrl-C still hard-exits`() async {
        let arbiter = HoldArbiter()
        _ = await arbiter.recordSignal(SIGHUP)
        await arbiter.beginTeardown()

        #expect(await arbiter.recordSignal(SIGHUP) == false)
        #expect(await arbiter.recordSignal(SIGINT) == true)
    }

    @Test func `only the first outcome is yielded`() async {
        let arbiter = HoldArbiter()
        _ = await arbiter.recordSignal(SIGINT)
        await arbiter.recordExpiry() // loses to the signal — must not yield again

        var iterator = arbiter.ends.makeAsyncIterator()
        guard case .interrupted? = await iterator.next() else {
            Issue.record("expected .interrupted")
            return
        }
        #expect(await iterator.next() == nil)
    }
}
