import Testing
@testable import DuckoUI

struct SetJSONArrayTests {
    @Test func `a set comes back from the text it was stored as`() {
        let set: Set = ["Work", "Friends", "old@example.com"]

        #expect(Set(jsonArray: set.jsonArray) == set)
    }

    @Test func `equal sets are stored alike`() {
        #expect(Set(["b", "a"]).jsonArray == #"["a","b"]"#)
        #expect(Set<String>().jsonArray == "[]")
    }

    @Test(arguments: ["", "not json", #"{"a":1}"#, "[1,2]"])
    func `a text that is no array of strings reads as empty`(text: String) {
        #expect(Set(jsonArray: text).isEmpty)
    }
}
