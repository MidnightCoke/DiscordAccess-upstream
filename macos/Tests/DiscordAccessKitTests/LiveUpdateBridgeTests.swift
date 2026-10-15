#if DISCORDACCESS_LIVE
import Foundation
import Testing
@testable import DiscordAccessKit

/// The update bridge on this Mac's own network, built only with `-Xswiftc -DDISCORDACCESS_LIVE`: a session's engine and
/// gate (automatic DNS selection) with the bridge in front of them, and the anonymous requests of Discord's updaters:
/// the old updater's feed, the new updater's manifest and the HEAD of one download. Nothing is downloaded; results are
/// printed with a `LIVE` prefix for the live report.
@Suite(.serialized) struct LiveUpdateBridgeTests {
    @Test func passesDiscordsUpdateRequestsThroughTheGate() throws {
        let image = try EngineImage.verify(path: TestEngine.path)
        let admission = try PeerAdmission(approved: [ProxyGateTests.netcat], readyTime: Date())
        let lines = ProxyGateTests.Collected<String>()
        let selected = try DnsSelection.select(.automatic, open: { provider, cancel in
            try DnsConnection.open(provider: provider, image: image, admission: admission, trace: lines.append, cancel: cancel)
        }, log: { print("LIVE " + $0) }, cancel: Cancellation())
        defer { try? selected.close() }
        let connection = try #require(selected as? DnsConnection)
        let failures = ProxyGateTests.Collected<String>()
        let bridge = try UpdateBridge(proxyPort: connection.gate.port, admission: admission, log: failures.append)
        bridge.start()
        defer { bridge.close() }
        // A minute between two reads, so that a stalled request ends with the bridge's own answer.
        func get(_ path: String, method: String = "GET") throws -> (head: String, body: [UInt8]) {
            let answer = try UpdateBridgeTests.exchange(bridge.port, UpdateBridgeTests.request(bridge, path, method: method), seconds: 60)
            print("LIVE " + method + " " + path.prefix(while: { $0 != "?" }) + ": " + (answer.head.components(separatedBy: "\r\n").first ?? "") + ", " +
                  String(answer.body.count) + " bytes")
            return answer
        }
        func addresses(_ value: Any) -> [String] {
            if let text = value as? String { return text.hasPrefix("http") ? [text] : [] }
            if let object = value as? [String: Any] { return object.values.flatMap(addresses) }
            if let array = value as? [Any] { return array.flatMap(addresses) }
            return []
        }
        let feed = try get("/legacy/updates/stable?platform=osx&version=0.0.300")
        #expect(feed.head.hasPrefix("HTTP/1.1 200 Response\r\n") && feed.head.contains("\r\nContent-Type: application/json; charset=utf-8\r\n"))
        let download = try #require(try JSONSerialization.jsonObject(with: Data(feed.body)) as? [String: Any])["url"] as? String
        let local = try #require(download?.hasPrefix(bridge.baseURL + "/download/") == true ? download : nil)
        let manifest = try get("/updates/distributions/app/manifests/latest?channel=stable&platform=osx&arch=universal")
        #expect(manifest.head.hasPrefix("HTTP/1.1 200 Response\r\n") && manifest.head.contains("\r\nContent-Type: application/json; charset=utf-8\r\n"))
        let rewritten = addresses(try JSONSerialization.jsonObject(with: Data(manifest.body)))
        print("LIVE manifest addresses: " + String(rewritten.count) + ", through the bridge: " +
              String(rewritten.filter { $0.hasPrefix(bridge.baseURL + "/download/") }.count))
        #expect(!rewritten.isEmpty && rewritten.allSatisfy { $0.hasPrefix(bridge.baseURL + "/download/") })
        let head = try get(String(local.dropFirst(bridge.baseURL.count)), method: "HEAD")
        #expect(head.head.hasPrefix("HTTP/1.1 200 Response\r\n") && head.head.contains("\r\nContent-Length: ") && head.body.isEmpty)
        #expect(failures.all.isEmpty, "\(failures.all)")
        for target in ["discord.com:443", "updates.discord.com:443", URL(string: local)!.pathComponents[3] + ":443"] {
            #expect(waitFor { lines.all.contains("Proxy: Owned request " + target) ? true : nil } == true, "\(target)")
        }
        let gateFailures = lines.all.filter { $0.contains("Failure") }
        print("LIVE gate failure lines: " + (gateFailures.isEmpty ? "none" : gateFailures.joined(separator: " | ")))
    }
}
#endif
