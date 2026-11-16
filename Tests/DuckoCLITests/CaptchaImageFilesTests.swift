import Darwin
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI
@testable import DuckoCore

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/// Serialized, since writing the files changes how the whole process handles SIGINT, SIGTERM and SIGHUP. The presence
/// hold's trap shares that handling, so its test runs here too.
@Suite(.serialized)
struct CaptchaImageFilesTests {
    private let captcha = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
        formType: .dataForm, instructions: nil, isRegistered: false,
        dataForm: DataForm(fields: [
            DataFormField(variable: "challenge", type: "hidden", values: ["123"]),
            DataFormField(variable: "ocr", type: "text-single", media: [DataFormMediaURI(type: "image/png", uri: "cid:a@bob.xmpp.org")]),
            DataFormField(variable: "picture_q", type: "text-single", media: [DataFormMediaURI(type: "image/jpeg", uri: "cid:b@bob.xmpp.org")]),
            DataFormField(variable: "picture_recog", type: "text-single", media: [DataFormMediaURI(type: "image/gif", uri: "cid:c@bob.xmpp.org")]),
            DataFormField(variable: "qa", type: "text-single", label: "What is 2 + 3?")
        ]),
        bitsOfBinary: [
            BitsOfBinaryData(cid: "a@bob.xmpp.org", type: "image/png", bytes: pngSignature),
            BitsOfBinaryData(cid: "b@bob.xmpp.org", type: "image/jpeg", bytes: [0xFF, 0xD8, 0xFF]),
            BitsOfBinaryData(cid: "c@bob.xmpp.org", type: "image/gif", bytes: Array("GIF89a".utf8))
        ]
    )).captcha

    @Test
    func `Each inline image is written owner-only, named by its challenge and type`() throws {
        let files = try #require(try CaptchaImageFiles.write(captcha))
        defer { files.remove() }

        #expect(files.images.map(\.variable) == ["ocr", "picture_q", "picture_recog"])
        #expect(files.images.map(\.url.lastPathComponent) == ["ocr.png", "picture_q.jpg", "picture_recog.gif"])
        for image in files.images {
            let permissions = try FileManager.default.attributesOfItem(atPath: image.url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
        let directory = try #require(files.images.first?.url.deletingLastPathComponent())
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700)
        #expect(try Data(contentsOf: files.images[0].url) == Data(pngSignature))
    }

    @Test
    func `While the images exist, Ctrl-C, a kill and a closing terminal are trapped`() throws {
        let files = try #require(try CaptchaImageFiles.write(captcha))
        defer { files.remove() }

        for signo in [SIGINT, SIGTERM, SIGHUP] {
            // Setting the same disposition again returns the current one, compared by address.
            let isTrapped = unsafeBitCast(signal(signo, SIG_IGN), to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
            #expect(isTrapped, "signal \(signo)")
        }
    }

    @Test
    func `Removing deletes the images and restores the default signal handling`() throws {
        let files = try #require(try CaptchaImageFiles.write(captcha))
        let directory = try #require(files.images.first?.url.deletingLastPathComponent())

        files.remove()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        for signo in [SIGINT, SIGTERM, SIGHUP] {
            // SIG_DFL is the null handler.
            let previousIsDefault = signal(signo, SIG_DFL) == nil
            #expect(previousIsDefault)
        }
    }

    @Test
    func `A signal the CLI started out ignoring, as under nohup, stays ignored`() throws {
        signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, SIG_DFL) }

        let files = try #require(try CaptchaImageFiles.write(captcha))
        files.remove()

        let isStillIgnored = unsafeBitCast(signal(SIGHUP, SIG_IGN), to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
        #expect(isStillIgnored)
    }

    @Test(arguments: [true, false])
    func `The presence hold traps a closing terminal unless the CLI started out ignoring it, as under nohup`(
        startsIgnored: Bool
    ) async {
        if startsIgnored { signal(SIGHUP, SIG_IGN) }
        defer {
            for signo in [SIGINT, SIGTERM, SIGHUP] {
                signal(signo, SIG_DFL)
            }
        }
        let monitor = InterruptMonitor.install()
        defer { monitor.cancel() }

        raise(SIGHUP)

        #expect(await firstSignal(of: monitor, within: .milliseconds(500)) == (startsIgnored ? nil : SIGHUP))
    }

    @Test
    func `A CAPTCHA without inline images writes nothing`() throws {
        let questionOnly = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm, instructions: nil, isRegistered: false,
            dataForm: DataForm(fields: [
                DataFormField(variable: "challenge", type: "hidden", values: ["123"]),
                DataFormField(variable: "qa", type: "text-single", label: "What is 2 + 3?")
            ])
        )).captcha

        #expect(try CaptchaImageFiles.write(questionOnly) == nil)
    }

    /// The first signal `monitor` reports within `timeout`, or nil.
    private func firstSignal(of monitor: InterruptMonitor, within timeout: Duration) async -> Int32? {
        let signals = monitor.signals
        return await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                var iterator = signals.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
