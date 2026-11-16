import Darwin
import Dispatch
import DuckoCore
import Foundation

/// A registration form's CAPTCHA images, written owner-only to a temporary directory so the user can open them while
/// answering. While they exist, a signal that ends the process removes them first, even during a prompt.
struct CaptchaImageFiles {
    /// Each written image, by the `var` of its challenge, in form order.
    let images: [(variable: String, url: URL)]
    private let directory: URL
    /// The signals trapped while the images exist, from `trappableTerminatingSignals()`.
    private let trappedSignals: [Int32]
    private let sources: [any DispatchSourceSignal]

    /// Writes the CAPTCHA's inline images, or returns nil when it has none.
    static func write(_ captcha: RegistrationCaptcha?) throws -> CaptchaImageFiles? {
        let inline = (captcha?.challenges ?? []).compactMap { challenge -> InlineImage? in
            guard case let .inline(data, format) = challenge.image else { return nil }
            return InlineImage(variable: challenge.variable, data: data, format: format)
        }
        guard !inline.isEmpty else { return nil }

        let directory = FileManager.default.temporaryDirectory.appending(path: "ducko-captcha-\(UUID().uuidString)")
        try FileManager.default.createOwnerOnlyDirectory(at: directory)
        let trappedSignals = trappableTerminatingSignals()
        let sources = removeOnTermination(directory, trapping: trappedSignals)
        var images: [(variable: String, url: URL)] = []
        do {
            for image in inline {
                let url = directory.appending(path: "\(image.variable).\(image.format.fileExtension)")
                try image.data.writeOwnerOnly(to: url)
                images.append((image.variable, url))
            }
        } catch {
            CaptchaImageFiles(images: images, directory: directory, trappedSignals: trappedSignals, sources: sources).remove()
            throw error
        }
        return CaptchaImageFiles(images: images, directory: directory, trappedSignals: trappedSignals, sources: sources)
    }

    /// An image sent with the form, for the challenge whose `var` is `variable`.
    private struct InlineImage {
        let variable: String
        let data: Data
        let format: CaptchaImageFormat
    }

    /// Deletes the images, then restores the default handling of the trapped signals.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        for source in sources {
            source.cancel()
        }
        for signo in trappedSignals {
            signal(signo, SIG_DFL)
        }
    }

    /// Ignores the signals' default action so their dispatch sources receive them. Each source deletes `directory`
    /// and exits with status 128 plus the signal number. In the terminal's foreground it first restores the terminal
    /// settings saved here. A hidden prompt turns echo off and turns it back on only when its read returns, which
    /// exiting skips. In the background the shell owns the terminal, and changing it would stop the process.
    private static func removeOnTermination(_ directory: URL, trapping signals: [Int32]) -> [any DispatchSourceSignal] {
        var terminal = termios()
        let savedTerminal = tcgetattr(STDIN_FILENO, &terminal) == 0 ? terminal : nil
        let queue = DispatchQueue(label: "im.ducko.cli.captcha-image-files")
        return signals.map { signo in
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler {
                try? FileManager.default.removeItem(at: directory)
                if var savedTerminal, tcgetpgrp(STDIN_FILENO) == getpgrp() {
                    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminal)
                }
                exit(exitCode(forSignal: signo))
            }
            source.activate()
            return source
        }
    }
}
