import Dispatch
import Foundation
import NIOCore
import NIOSSL
@preconcurrency import Security

/// Evaluates the server's chain against `serverName`, a DNS name or an IP address, and the injected and system roots.
/// NIOSSL reports a failed verification without its reason, so `onRejection` receives the reason on the promise's event
/// loop before the promise reports the failure. NIOSSL also couples its IP identity check to the dialed address, while
/// XMPP host overrides must retain the account identity.
func verifyCertificateChain(
    _ chain: [NIOSSLCertificate], serverName: String, trustRoots: [[UInt8]], promise: EventLoopPromise<NIOSSLVerificationResult>,
    onRejection: @escaping @Sendable (CertificateTrustFailure) -> Void
) {
    do {
        let certificates = try chain.map { try securityCertificate($0.toDERBytes()) }
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            throw verificationError
        }
        if !trustRoots.isEmpty {
            let anchors = try trustRoots.map(securityCertificate)
            guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else {
                throw verificationError
            }
        }
        let queue = DispatchQueue(label: "im.ducko.xmpp.trust")
        // Security requires invocation on the same queue that receives its asynchronous completion.
        queue.async {
            let status = SecTrustEvaluateAsyncWithError(trust, queue) { _, verified, error in
                guard !verified else {
                    promise.succeed(.certificateVerified)
                    return
                }
                let reason = certificateTrustFailure(forStatus: error.map(CFErrorGetCode) ?? Int(errSecNotTrusted))
                promise.futureResult.eventLoop.execute {
                    onRejection(reason)
                    promise.succeed(.failed)
                }
            }
            if status != errSecSuccess { promise.fail(verificationError) }
        }
    } catch {
        promise.fail(error)
    }
}

/// The reason a trust evaluation failed with `status`, a `SecBase.h` result code.
func certificateTrustFailure(forStatus status: Int) -> CertificateTrustFailure {
    switch OSStatus(truncatingIfNeeded: status) {
    case errSecHostNameMismatch: .nameMismatch
    case errSecCertificateExpired, errSecCertificateNotValidYet: .outsideValidityPeriod
    default: .notTrusted
    }
}

private let verificationError = XMPPClientError.tlsNegotiationFailed("The server certificate could not be verified")

private func securityCertificate(_ bytes: [UInt8]) throws -> SecCertificate {
    guard let certificate = SecCertificateCreateWithData(nil, Data(bytes) as CFData) else { throw verificationError }
    return certificate
}
