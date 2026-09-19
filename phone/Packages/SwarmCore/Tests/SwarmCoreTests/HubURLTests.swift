import Foundation
import Testing
@testable import SwarmCore

@Suite("Hub URL: from a scanned QR to the phone socket")
struct HubURLTests {
    @Test(arguments: [
        ("http://10.120.4.246:8000/", "ws://10.120.4.246:8000/ws/phone"),
        ("http://10.120.4.246:8000", "ws://10.120.4.246:8000/ws/phone"),
        ("http://localhost:8000/dashboard?x=1#frag", "ws://localhost:8000/ws/phone"),
        ("https://swarm.example.dev/", "wss://swarm.example.dev/ws/phone"),
        ("https://abc-123.trycloudflare.com", "wss://abc-123.trycloudflare.com/ws/phone"),
        ("https://10.120.4.246:8443/", "ws://10.120.4.246:8000/ws/phone"),
        ("https://10.120.4.246/", "ws://10.120.4.246:8000/ws/phone"),
        ("ws://10.0.0.5:8000/ws/phone", "ws://10.0.0.5:8000/ws/phone"),
        ("wss://swarm.example.dev/ws/phone", "wss://swarm.example.dev/ws/phone"),
        ("10.0.0.5:8000", "ws://10.0.0.5:8000/ws/phone"),
        ("  http://10.0.0.5:8000/\n", "ws://10.0.0.5:8000/ws/phone"),
        ("swarmsight://join?hub=http%3A%2F%2F10.0.0.5%3A8000%2F", "ws://10.0.0.5:8000/ws/phone"),
        ("swarmsight://join?hub=https://10.0.0.5:8443/&replay=1", "ws://10.0.0.5:8000/ws/phone"),
    ])
    func derives(scanned: String, expected: String) {
        #expect(HubURL.derive(scanned)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://host/", "swarmsight://join", "swarmsight://join?hub=", "http://"])
    func rejects(scanned: String) {
        #expect(HubURL.derive(scanned) == nil)
    }

    @Test func aDeepLinkCannotRecurseForever() {
        var link = "http://10.0.0.5:8000/"
        for _ in 0..<6 {
            link = "swarmsight://join?hub=" + (link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        #expect(HubURL.derive(link) == nil)
    }
}
