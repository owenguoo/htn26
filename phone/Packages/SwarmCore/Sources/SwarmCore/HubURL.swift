import Foundation

/// Turns whatever the operator scanned or typed into the hub's phone socket.
///
/// The dashboard QR encodes the *web page* a browser phone would open, not a
/// socket, and it comes in three flavours (`hub.py` `main`):
///
/// - `http://<lan-ip>:8000/` — plain. → `ws://<lan-ip>:8000/ws/phone`
/// - `https://<tunnel-host>/` — a real certificate. → `wss://<tunnel-host>/ws/phone`
/// - `https://<lan-ip>:8443/` — the hub's self-signed certificate, which exists
///   only because browsers need HTTPS for the camera. A native app does not, and
///   URLSession would refuse the certificate, so this falls back to the plain
///   port on the same host: `ws://<lan-ip>:8000/ws/phone`.
///
/// Query and fragment are dropped.
public enum HubURL {
    public static let plainPort = 8000
    public static let selfSignedPort = 8443
    public static let socketPath = "/ws/phone"

    public static func derive(_ scanned: String) -> URL? {
        derive(scanned, depth: 0)
    }

    private static func derive(_ scanned: String, depth: Int) -> URL? {
        var text = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, depth < 3 else { return nil }
        // A bare "10.0.0.5:8000" typed by hand.
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else { return nil }

        if scheme == "swarmsight" {
            guard let hub = components.queryItems?.first(where: { $0.name == "hub" })?.value else {
                return nil
            }
            return derive(hub, depth: depth + 1)
        }

        guard let host = components.host, !host.isEmpty else { return nil }
        var out = URLComponents()
        out.host = host
        out.path = socketPath
        switch scheme {
        case "http", "ws":
            out.scheme = "ws"
            out.port = components.port
        case "https", "wss":
            if isIPAddress(host) {
                // Self-signed on the LAN: no certificate a phone would trust.
                out.scheme = "ws"
                out.port = (components.port == nil || components.port == selfSignedPort)
                    ? plainPort : components.port
            } else {
                out.scheme = "wss"
                out.port = components.port
            }
        default:
            return nil
        }
        return out.url
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 literal
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
