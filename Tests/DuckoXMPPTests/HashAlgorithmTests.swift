import Testing
@testable import DuckoXMPP

struct HashAlgorithmTests {
    @Test(arguments: [(HashAlgorithm.sha256, 32), (.sha512, 64)])
    func `Each algorithm produces its digest length`(algorithm: HashAlgorithm, length: Int) {
        #expect(algorithm.hash(Array("test".utf8)).count == length)
    }

    @Test
    func `Raw values match XEP-0300 algorithm names`() {
        #expect(HashAlgorithm.sha256.rawValue == "sha-256")
        #expect(HashAlgorithm.sha512.rawValue == "sha-512")
    }

    @Test
    func `The strongest supported hash wins wherever it is listed`() {
        let file = Self.file(hashes: [("sha-1", nil), ("sha-512", nil), ("sha-256", nil)])
        #expect(HashAlgorithm.preferredHash(in: file)?.attribute("algo") == "sha-512")
    }

    @Test
    func `Without a supported hash the first one is kept`() {
        let file = Self.file(hashes: [("sha-1", nil), ("md5", nil)])
        #expect(HashAlgorithm.preferredHash(in: file)?.attribute("algo") == "sha-1")
    }

    @Test
    func `A hash outside the hashes namespace is ignored`() {
        let file = Self.file(hashes: [("sha-256", "urn:example:other")])
        #expect(HashAlgorithm.preferredHash(in: file) == nil)
    }

    private static func file(hashes: [(algo: String, namespace: String?)]) -> XMLElement {
        var file = XMLElement(name: "file")
        for hash in hashes {
            file.addChild(XMLElement(name: "hash", namespace: hash.namespace ?? XMPPNamespaces.hashes2, attributes: ["algo": hash.algo]))
        }
        return file
    }
}
