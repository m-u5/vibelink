import Foundation

public struct TailscalePeer: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let hostName: String
    public let dnsName: String
    public let os: String
    public let ips: [String]
    public let online: Bool

    public var ipv4: String? { ips.first { $0.contains(".") } }
    public var shortDNSName: String { dnsName.split(separator: ".").first.map(String.init) ?? hostName }
    public var isIOS: Bool { os.lowercased() == "ios" }
    public var isAndroid: Bool { os.lowercased() == "android" }
}

public enum Tailscale {
    public static var binary: String? {
        Shell.find([
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ])
    }

    public static func peers() throws -> [TailscalePeer] {
        guard let bin = binary else { throw ShellError.notFound("tailscale") }
        let r = try Shell.run(bin, ["status", "--json"], timeout: 10)
        guard r.status == 0 else { throw ShellError.failed("tailscale status", r.status, r.stderr) }
        return try parse(Data(r.stdout.utf8))
    }

    static func parse(_ data: Data) throws -> [TailscalePeer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = root["Peer"] as? [String: [String: Any]] else { return [] }
        return peers.values.map { p in
            TailscalePeer(
                id: p["ID"] as? String ?? (p["PublicKey"] as? String ?? UUID().uuidString),
                hostName: p["HostName"] as? String ?? "",
                dnsName: p["DNSName"] as? String ?? "",
                os: p["OS"] as? String ?? "",
                ips: p["TailscaleIPs"] as? [String] ?? [],
                online: p["Online"] as? Bool ?? false)
        }.sorted { $0.shortDNSName < $1.shortDNSName }
    }
}
