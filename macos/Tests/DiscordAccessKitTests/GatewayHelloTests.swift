import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DiscordAccessKit

/// The Gateway WebSocket check against a loopback stand-in for the proxy and the Gateway. URLSession sends a plain
/// `ws://fixture.invalid/...` upgrade to the proxy in absolute form (with the `ws` scheme), so the stand-in completes the
/// handshake itself and then acts out its script; the `.invalid` name never resolves. Vectors from the Windows
/// `GatewayChecks.RunOfflineChecks`.
@Suite struct GatewayHelloTests {
    typealias Collected = ProxyGateTests.Collected
    static let target = URL(string: "ws://fixture.invalid/gateway?v=10&encoding=json")!
    static let hello = "{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}"

    enum Script {
        /// Answers the upgrade with 403.
        case refuse
        /// Completes the handshake, then sends one text message.
        case text(String)
        case binary
        /// A text message over the 16 KiB limit.
        case oversized
        /// A close frame instead of HELLO.
        case close
        /// Nothing after the handshake.
        case silent
    }

    final class FixtureGateway {
        let listener: TCPListener
        let heads = Collected<String>()
        /// The opcodes of the frames the client sent, and the status code of its closing frame.
        let clientFrames = Collected<UInt8>()
        let closeCodes = Collected<Int>()
        private let served = DispatchGroup()

        var port: UInt16 { listener.port }

        init(_ script: Script) throws {
            listener = try TCPListener()
            let (listener, heads, clientFrames, closeCodes, served) = (listener, heads, clientFrames, closeCodes, served)
            served.enter()
            Thread {
                defer { served.leave() }
                guard let client = try? listener.acceptClient().descriptor else { return }
                defer { close(client) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                let head = ConnectivityProbeTests.FixtureProxy.readHead(client)
                heads.append(head)
                if case .refuse = script {
                    _ = try? RelayTests.send(client, ConnectivityProbeTests.FixtureProxy.response(403, contentType: "text/html"))
                    return
                }
                let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                    .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                var reply = Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                    accept + "\r\n\r\n").utf8)
                switch script {
                case .refuse, .silent: break
                case .text(let text): reply += FixtureGateway.frame(opcode: 1, payload: Array(text.utf8))
                case .binary: reply += FixtureGateway.frame(opcode: 2, payload: Array(GatewayHelloTests.hello.utf8))
                case .oversized: reply += FixtureGateway.frame(opcode: 1, payload: Array(repeating: UInt8(ascii: " "), count: 16_385))
                case .close: reply += FixtureGateway.frame(opcode: 8, payload: [0x03, 0xE8])
                }
                guard (try? RelayTests.send(client, reply)) != nil else { return }
                while let frame = FixtureGateway.readFrame(client) {
                    clientFrames.append(frame.opcode)
                    if frame.opcode == 8 {
                        closeCodes.append(frame.payload.count >= 2 ? Int(frame.payload[0]) << 8 | Int(frame.payload[1]) : 0)
                        break
                    }
                }
            }.start()
        }

        /// Waits until the connection was served, at most 15 seconds.
        func finished() -> Bool { served.wait(timeout: .now() + 15) == .success }

        /// One unmasked frame from the server.
        static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
            var bytes: [UInt8] = [0x80 | opcode]
            if payload.count < 126 {
                bytes.append(UInt8(payload.count))
            } else if payload.count <= 0xFFFF {
                bytes += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
            } else {
                bytes.append(127)
                bytes += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
            }
            return bytes + payload
        }

        /// The client's next frame, unmasked, or nil at the end of the stream.
        static func readFrame(_ descriptor: Int32) -> (opcode: UInt8, payload: [UInt8])? {
            guard let start = ProxyGateTests.receive(descriptor, count: 2) else { return nil }
            var length = Int(start[1] & 0x7F)
            if length == 126 {
                guard let extended = ProxyGateTests.receive(descriptor, count: 2) else { return nil }
                length = Int(extended[0]) << 8 | Int(extended[1])
            } else if length == 127 {
                guard let extended = ProxyGateTests.receive(descriptor, count: 8) else { return nil }
                length = extended.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let mask = start[1] & 0x80 != 0 ? ProxyGateTests.receive(descriptor, count: 4) : [0, 0, 0, 0],
                  let payload = ProxyGateTests.receive(descriptor, count: length) else { return nil }
            return (start[0] & 0x0F, payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
    }

    static func failure(_ body: () throws -> Void) -> GatewayHelloFailure? {
        do {
            try body()
            return nil
        } catch {
            return error as? GatewayHelloFailure
        }
    }

    @Test func readsTheHelloAndClosesWithoutSendingAMessage() throws {
        let gateway = try FixtureGateway(.text(Self.hello))
        try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation())
        #expect(gateway.finished())
        let head = try #require(gateway.heads.all.first)
        #expect(head.hasPrefix("GET ws://fixture.invalid/gateway?v=10&encoding=json HTTP/1.1\r\n"))
        #expect(head.lowercased().contains("\r\nupgrade: websocket\r\n") && !head.lowercased().contains("authorization"))
        let fields = ConnectivityProbeTests.fields(head)
        #expect(fields["user-agent"] == "DiscordAccess/3 (connectivity check)" && fields["accept-language"] == "en" && fields["accept-encoding"] == "identity")
        // Public HELLO only: the client never sends a text or binary message, only its closing frame, and it closes
        // normally (1000) rather than as a reset or a client going away.
        #expect(gateway.clientFrames.all == [8])
        #expect(gateway.closeCodes.all == [1000])
    }

    @Test(arguments: ["null", "[]", "{}", "SYNTHETIC_SECRET", "{\"op\":0,\"d\":{\"heartbeat_interval\":41250}}", "{\"op\":10,\"d\":{}}",
                      "{\"op\":10,\"d\":{\"heartbeat_interval\":0}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":\"45000\"}}",
                      "{\"op\":10,\"d\":{\"heartbeat_interval\":300001}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":41250.5}}",
                      "{\"op\":true,\"d\":{\"heartbeat_interval\":41250}}", "{\"op\":10,\"d\":{\"heartbeat_interval\":true}}"])
    func refusesAMessageThatIsNotAHello(text: String) throws {
        let gateway = try FixtureGateway(.text(text))
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .response))
        #expect(failure.map { !$0.message.contains("SYNTHETIC_SECRET") } == true)
    }

    @Test(arguments: [Script.binary, .oversized, .close])
    func refusesABinaryOversizedOrClosingAnswer(script: Script) throws {
        let gateway = try FixtureGateway(script)
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .response))
    }

    @Test func reportsARefusedHandshakeBeforeTheConnectionOpens() throws {
        let gateway = try FixtureGateway(.refuse)
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: false, reason: .webSocket))
        #expect(failure?.message.hasPrefix("[WS-CONNECT-WEBSOCKET] ") == true)
    }

    @Test func failsAtOnceWhenTheProxyRefuses() throws {
        let port = try ConnectivityProbeTests.refusedPort(in: 23_200..<23_400)
        let started = Date()
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: port, cancel: Cancellation()) }
        #expect(failure == GatewayHelloFailure(opened: false, reason: .transport))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func endsAtItsDeadlineWhenTheHelloDoesNotCome() throws {
        let gateway = try FixtureGateway(.silent)
        let started = Date()
        let failure = Self.failure { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: Cancellation(), deadline: 0.5) }
        #expect(failure == GatewayHelloFailure(opened: true, reason: .timeout))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func endsAtOnceWhenCanceled() throws {
        let gateway = try FixtureGateway(.silent)
        let cancel = Cancellation()
        Thread {
            usleep(200_000)
            cancel.cancel()
        }.start()
        let started = Date()
        #expect(throws: CancellationError.self) { try GatewayHello.check(url: Self.target, proxyPort: gateway.port, cancel: cancel) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    static let reasons: [(Error, Bool, GatewayHelloFailure.Reason)] = [
        (URLError(.networkConnectionLost), true, .response),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE)), false, .response),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)), false, .transport),
        (NSError(domain: NSURLErrorDomain, code: 310), false, .transport),
        (NSError(domain: kCFErrorDomainCFNetwork as String, code: 306), false, .transport),
        (URLError(.badServerResponse), false, .webSocket),
        (URLError(.secureConnectionFailed), false, .transport),
        (URLError(.timedOut), false, .timeout),
        (URLError(.cancelled), false, .canceled),
        (URLError(.unknown), false, .failed),
        (NSError(domain: "SYNTHETIC_SECRET", code: 1), false, .failed),
    ]

    /// Windows `FailureCategory`: a closing peer counts first, then the proxy, POSIX and URLSession codes.
    @Test func classifiesAFailureWithAFixedReason() {
        for (error, closedByPeer, reason) in Self.reasons {
            #expect(GatewayHello.reason(for: error, closedByPeer: closedByPeer) == reason)
        }
    }

    @Test func namesTheStageAndAFixedReasonOnly() {
        #expect(GatewayHelloFailure(opened: true, reason: .timeout).message ==
            "[WS-HELLO-TIMEOUT] Gateway WebSocket kontrolü tamamlanamadı. HTTP API başarısı canlı mesaj bağlantısını doğrulamaz.")
        #expect(GatewayHelloFailure(opened: false, reason: .canceled).description.hasPrefix("[WS-CONNECT-CANCELLED] "))
        #expect(GatewayHelloFailure(opened: false, reason: .failed).description.hasPrefix("[WS-CONNECT-FAILED] "))
        #expect(GatewayHello.valid(hello: Self.hello))
        #expect(GatewayHello.url.absoluteString == "wss://gateway.discord.gg/?v=10&encoding=json")
    }
}
