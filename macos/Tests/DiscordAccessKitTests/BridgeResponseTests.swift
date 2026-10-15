import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The bridge's own response headers and diagnostic lines (Windows `WriteHeader` and `DescribeFailure` vectors).
@Suite struct BridgeResponseTests {
    @Test func writesAClosingUncachedResponseHeader() throws {
        #expect(String(decoding: try BridgeResponse.header(status: 200, contentType: "application/json", length: 25, location: nil), as: UTF8.self) ==
            "HTTP/1.1 200 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n")
        #expect(String(decoding: try BridgeResponse.header(status: 302, contentType: " ", length: nil, location: "http://127.0.0.1:1/t/download/a"), as: UTF8.self) ==
            "HTTP/1.1 302 Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/octet-stream\r\nLocation: http://127.0.0.1:1/t/download/a\r\n\r\n")
        #expect(try BridgeResponse.header(status: 403, contentType: "text/plain", length: 0, location: nil) == BridgeResponse.forbidden)
    }

    @Test func refusesAHeaderValueItCannotWriteSafely() {
        for (status, type, length, location) in [(199, "text/plain", Int64(0), String?.none), (600, "text/plain", 0, nil), (200, "text/plain\r\nX: y", 0, nil),
                                                 (200, String(repeating: "a", count: 257), 0, nil), (200, "text/plain", -1, nil),
                                                 (302, "text/plain", 0, "http://127.0.0.1/a b"), (302, "text/plain", 0, "http://127.0.0.1/a\r\nX: y")] {
            #expect(throws: BridgeFailure.invalidData) { try BridgeResponse.header(status: status, contentType: type, length: length, location: location) }
        }
    }

    @Test func announcesALengthOnlyWhenItIsKnown() {
        #expect(BridgeResponse.length(rewritten: 12, json: true, contentLength: 500, contentEncoding: nil, status: 200) == 12)
        #expect(BridgeResponse.length(rewritten: nil, json: false, contentLength: 500, contentEncoding: nil, status: 200) == 500)
        #expect(BridgeResponse.length(rewritten: nil, json: false, contentLength: 500, contentEncoding: "", status: 200) == 500)
        #expect(BridgeResponse.length(rewritten: nil, json: false, contentLength: 500, contentEncoding: "gzip", status: 200) == nil)
        #expect(BridgeResponse.length(rewritten: nil, json: false, contentLength: -1, contentEncoding: nil, status: 200) == nil)
        #expect(BridgeResponse.length(rewritten: nil, json: true, contentLength: 500, contentEncoding: nil, status: 200) == nil)
        #expect(BridgeResponse.length(rewritten: nil, json: false, contentLength: 500, contentEncoding: nil, status: 204) == nil)
        #expect(BridgeResponse.length(rewritten: 12, json: true, contentLength: 500, contentEncoding: nil, status: 304) == nil)
    }

    /// Fixed stage, category, status and error numbers only; never a URL, token, header, body or error message.
    @Test func describesAFailureWithoutWhatItCarried() {
        let secret = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                             userInfo: [NSURLErrorFailingURLStringErrorKey: "https://discord.com/private?token=SYNTHETIC_SECRET"])
        #expect(BridgeResponse.describe(stage: .upstreamResponse, failure: .upstream(secret), status: nil) ==
            "stage=UpstreamResponse; category=upstream-network; url-error=-1004")
        #expect(BridgeResponse.describe(stage: .clientResponseBody, failure: .io(ECONNRESET), status: 200) ==
            "stage=ClientResponseBody; category=io; HTTP=200; socket=ConnectionReset")
        #expect(BridgeResponse.describe(stage: .clientHeader, failure: .io(nil), status: nil) == "stage=ClientHeader; category=io")
        #expect(BridgeResponse.describe(stage: .clientHeader, failure: .timeout, status: nil) == "stage=ClientHeader; category=timeout")
        #expect(BridgeResponse.describe(stage: .upstreamResponse, failure: .upstream(NSError(domain: kCFErrorDomainCFNetwork as String, code: 310)), status: nil) ==
            "stage=UpstreamResponse; category=upstream-network; cfnetwork-error=310")
        #expect(BridgeResponse.describe(stage: .upstreamBody, failure: .upstream(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))), status: 200) ==
            "stage=UpstreamBody; category=upstream-network; HTTP=200; socket=Shutdown")
        #expect(BridgeResponse.describe(stage: .manifestRewrite, failure: .unexpected, status: 200) == "stage=ManifestRewrite; category=unexpected; HTTP=200")
        #expect(BridgeResponse.describe(stage: .clientRequest, failure: .invalidData, status: nil) == "stage=ClientRequest; category=invalid-data")
        #expect(BridgeResponse.describe(stage: .upstreamResponse, failure: .canceled, status: nil) == "stage=UpstreamResponse; category=cancelled")
        #expect(BridgeResponse.describe(stage: .clientResponseHeader, failure: .socket(EMFILE), status: 200) ==
            "stage=ClientResponseHeader; category=socket; HTTP=200; socket=TooManyOpenSockets")
        #expect(BridgeResponse.describe(stage: .upstreamResponse, failure: .upstream(NSError(domain: "SYNTHETIC_SECRET", code: 7)), status: nil) ==
            "stage=UpstreamResponse; category=upstream-network")
    }

    @Test func keepsURLSessionTimeoutsAndCancellationsInTheirCategories() {
        #expect(BridgeFailure.upstream(URLError(.timedOut)) == .timeout)
        #expect(BridgeFailure.upstream(URLError(.cancelled)) == .canceled)
        #expect(BridgeFailure.upstream(URLError(.networkConnectionLost)) == .upstream(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        #expect(BridgeFailure(GateFailure.timeout) == .timeout && BridgeFailure(GateFailure.canceled) == .canceled)
        #expect(BridgeFailure(GateFailure.io(EPIPE)) == .io(EPIPE) && BridgeFailure(GateFailure.socket(EMFILE)) == .socket(EMFILE))
        #expect(BridgeFailure(GateFailure.invalidData) == .invalidData && BridgeFailure(GateFailure.unexpected) == .unexpected)
    }
}
