import CryptoKit
import Testing
@testable import DuckoXMPP

struct CaptchaProofOfWorkSolverTests {
    /// The first counter after `slowPrefix` whose digest ends with `slowLabel` is 3,002,338, checked by brute force,
    /// far more attempts than fit in a short time limit or a small attempt cap.
    private static let slowPrefix = "deadline-fixture@example.com"
    private static let slowLabel = "00004"

    @Test(arguments: ["example.com", "ducko.im"], ["7", "a3f", "B2C"])
    func `A solved answer is the prefix and a counter whose SHA-256 digest ends with the label`(prefix: String, label: String) async throws {
        let answer = try #require(await CaptchaProofOfWorkSolver.solve(prefix: prefix, label: label))

        let counterIsDecimal = answer.dropFirst(prefix.count).allSatisfy(\.isASCII) && Int(answer.dropFirst(prefix.count)) != nil
        #expect(answer.hasPrefix(prefix))
        #expect(counterIsDecimal)
        #expect(hexString(SHA256.hash(data: Array(answer.utf8))).lowercased().hasSuffix(label.lowercased()))
    }

    @Test
    func `A label over five hex digits is refused before hashing`() async {
        let start = ContinuousClock.now

        let answer = await CaptchaProofOfWorkSolver.solve(prefix: "example.com", label: "abcdef")

        #expect(answer == nil)
        #expect(ContinuousClock.now - start < .milliseconds(10))
    }

    @Test(arguments: ["", "12g", "١٢", "ａ"])
    func `A label that is empty or not ASCII hex is refused`(label: String) async {
        #expect(await CaptchaProofOfWorkSolver.solve(prefix: "example.com", label: label) == nil)
    }

    @Test
    func `The solver gives up at its attempt cap`() async {
        #expect(await CaptchaProofOfWorkSolver.solve(prefix: Self.slowPrefix, label: Self.slowLabel, attempts: 1000) == nil)
    }

    @Test
    func `The solver gives up at its time limit`() async {
        let start = ContinuousClock.now

        let answer = await CaptchaProofOfWorkSolver.solve(prefix: Self.slowPrefix, label: Self.slowLabel, timeLimit: .milliseconds(50))

        #expect(answer == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test
    func `A cancelled solve returns nil promptly`() async {
        let solve = Task { await CaptchaProofOfWorkSolver.solve(prefix: Self.slowPrefix, label: Self.slowLabel, timeLimit: .seconds(60)) }
        let start = ContinuousClock.now

        solve.cancel()

        #expect(await solve.value == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test
    func `A 249-byte prefix is solved within 256 bytes, and a longer one is refused`() async throws {
        let longest = String(repeating: "a", count: 249)

        let answer = try #require(await CaptchaProofOfWorkSolver.solve(prefix: longest, label: "1"))

        #expect(answer.utf8.count <= 256)
        #expect(await CaptchaProofOfWorkSolver.solve(prefix: longest + "a", label: "1") == nil)
    }

    @Test
    func `A prefix is measured in UTF-8 bytes, not characters`() async {
        let domain = String(repeating: "ü", count: 125)

        #expect(domain.count < 249)
        #expect(await CaptchaProofOfWorkSolver.solve(prefix: domain, label: "1") == nil)
    }
}
