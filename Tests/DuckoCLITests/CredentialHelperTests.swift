import Testing
@testable import DuckoCLI

struct CredentialHelperTests {
    @Test(arguments: [(4094, true), (4095, false)])
    func `A hidden line that fills the read buffer is refused`(length: Int, isTaken: Bool) {
        let line = String(repeating: "x", count: length)

        #expect((try? CredentialHelper.wholeHiddenLine(line)) == (isTaken ? line : nil))
    }
}
