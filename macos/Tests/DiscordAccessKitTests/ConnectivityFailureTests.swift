import Foundation
import Testing
@testable import DiscordAccessKit

/// Vectors from the Windows `ConnectivityChecks.RunFailureChecks`. A message holds only fixed words, an HTTP status and
/// a response type, so `PRIVATE` must never appear.
@Suite struct ConnectivityFailureTests {
    static let secret = "SYNTHETIC_SECRET https://private.invalid/?token=PRIVATE /Users/PRIVATE/config.json\u{1B}"

    @Test(arguments: [
        (ConnectivityFailure.Reason.dns, "DNS resolution failed"),
        (.tls, "TLS connection or certificate validation failed"),
        (.connect, "could not connect to the network or the local proxy"),
        (.timeout, "timed out"),
        (.invalidResponse, "the expected response format could not be verified"),
        (.responseTooLarge, "the response exceeds the size limit"),
        (.incompleteResponse, "the response transfer did not finish"),
        (.canceled, "the operation was canceled"),
        (.other, "access could not be verified"),
    ])
    func namesTheEndpointAndTheReason(reason: ConnectivityFailure.Reason, detail: String) {
        #expect(ConnectivityFailure(endpoint: .gateway, reason: reason).message == "Discord Gateway API check failed (" + detail + ").")
        #expect(ConnectivityFailure(endpoint: .updates, reason: reason).description == "Discord update server check failed (" + detail + ").")
    }

    @Test func keepsAnHTTPStatusOnlyWhenItIsOne() {
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429, responseKind: .html).message ==
            "Discord Gateway API check failed (HTTP 429; response type HTML).")
        #expect(ConnectivityFailure(endpoint: .updates, reason: .http, httpStatus: 503, responseKind: .json).message ==
            "Discord update server check failed (HTTP 503; response type JSON).")
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .invalidResponse, responseKind: .other).message ==
            "Discord Gateway API check failed (the expected response format could not be verified; response type other).")
        for status in [-1, 0, 99, 600, Int.max] {
            let failure = ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: status)
            #expect(failure.httpStatus == 0 && failure.message == "Discord Gateway API check failed (HTTP error response).")
        }
        #expect(ConnectivityFailure(endpoint: .gateway, reason: .timeout, httpStatus: 429).httpStatus == 0)
    }

    @Test func classifiesTheResponseTypeWithoutKeepingIt() {
        #expect(ConnectivityFailure.responseKind(contentType: "Application/JSON; charset=utf-8") == .json)
        #expect(ConnectivityFailure.responseKind(contentType: "text/json") == .json)
        #expect(ConnectivityFailure.responseKind(contentType: "text/html; PRIVATE") == .html)
        #expect(ConnectivityFailure.responseKind(contentType: " application/xhtml+xml ") == .html)
        #expect(ConnectivityFailure.responseKind(contentType: Self.secret) == .other)
        #expect(ConnectivityFailure.responseKind(contentType: "application/json" + String(repeating: " ", count: 300)) == .other)
        for empty in [nil, "", "   "] as [String?] {
            #expect(ConnectivityFailure.responseKind(contentType: empty) == ConnectivityFailure.ResponseKind.none)
        }
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ConnectivityFailure.Reason.timeout), (.cancelled, .canceled), (.cannotFindHost, .dns), (.dnsLookupFailed, .dns),
        (.secureConnectionFailed, .tls), (.serverCertificateUntrusted, .tls), (.serverCertificateHasUnknownRoot, .tls),
        (.cannotConnectToHost, .connect), (.notConnectedToInternet, .connect), (.networkConnectionLost, .incompleteResponse),
        (.badServerResponse, .invalidResponse), (.cannotParseResponse, .invalidResponse), (.dataLengthExceedsMaximum, .responseTooLarge),
        (.unsupportedURL, .other),
    ])
    func classifiesURLSessionErrors(code: URLError.Code, reason: ConnectivityFailure.Reason) {
        let error = NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: Self.secret])
        let failure = ConnectivityFailure.from(error, endpoint: .updates, expired: false)
        #expect(failure == ConnectivityFailure(endpoint: .updates, reason: reason))
        #expect(!String(describing: failure).contains("PRIVATE") && !failure.message.contains("SYNTHETIC_SECRET"))
    }

    @Test func classifiesProxyFailuresTheDeadlineAndOtherErrors() {
        // CFNetwork's codes for a proxy it cannot use, as data and WebSocket tasks report them.
        for domain in [kCFErrorDomainCFNetwork as String, NSURLErrorDomain] {
            for code in [306, 310, 311] {
                #expect(ConnectivityFailure.from(NSError(domain: domain, code: code), endpoint: .gateway, expired: false).reason == .connect)
            }
        }
        // The check's own deadline cancels the task; that is a timeout, not a user's cancellation.
        #expect(ConnectivityFailure.from(URLError(.cancelled), endpoint: .gateway, expired: true).reason == .timeout)
        // Socket errors as Windows `SocketException`.
        #expect(ConnectivityFailure.from(POSIXError(.ECONNRESET), endpoint: .gateway, expired: false).reason == .connect)
        #expect(ConnectivityFailure.from(POSIXError(.ECONNREFUSED), endpoint: .gateway, expired: false).reason == .connect)
        #expect(ConnectivityFailure.from(POSIXError(.ETIMEDOUT), endpoint: .gateway, expired: false).reason == .timeout)
        #expect(ConnectivityFailure.from(POSIXError(.EPERM), endpoint: .gateway, expired: false).reason == .other)
        #expect(ConnectivityFailure.from(NSError(domain: "PRIVATE", code: 310), endpoint: .gateway, expired: false).reason == .other)
        let known = ConnectivityFailure(endpoint: .gateway, reason: .http, httpStatus: 429)
        #expect(ConnectivityFailure.from(known, endpoint: .updates, expired: false) == known)
    }
}
