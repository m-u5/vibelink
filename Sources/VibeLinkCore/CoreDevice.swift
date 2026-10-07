import Foundation

/// A device as reported by `xcrun devicectl list devices`.
public struct CoreDeviceInfo {
    public let name: String
    public let hostnames: [String]

    /// "My-iPhone" from "My-iPhone.coredevice.local"; matches the Bonjour host of the device's adverts.
    public var hostKey: String? { hostnames.first.flatMap { $0.components(separatedBy: ".coredevice.local").first } }
}

public enum CoreDevice {
    public static func list() throws -> [CoreDeviceInfo] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vibelink-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--json-output", out.path], timeout: 30)
        guard r.status == 0 else { throw ShellError.failed("devicectl list devices", r.status, r.stderr) }
        let data = try Data(contentsOf: out)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.map { d in
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let dev = d["deviceProperties"] as? [String: Any] ?? [:]
            return CoreDeviceInfo(name: dev["name"] as? String ?? "",
                                  hostnames: conn["potentialHostnames"] as? [String] ?? [])
        }
    }
}
