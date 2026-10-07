import Foundation

/// remotepairingd connects the CoreDevice tunnel to a port the iPhone picks at runtime. It logs that
/// endpoint publicly ("Got tunnel endpoint: '<ip>%<if>:<port>'"), and the iPhone hands out ports
/// sequentially, so watching the log lets us pre-open the next ports before they are requested.
final class TunnelPortWatcher {
    static let predicate = #"process == "remotepairingd" AND eventMessage CONTAINS "Got tunnel endpoint""#
    private static let regex = try! NSRegularExpression(pattern: #"Got tunnel endpoint: '([^']+):(\d+)'"#)

    private var process: Process?
    private var buffer = Data()
    private let onPort: (_ host: String, _ port: Int) -> Void

    init(onPort: @escaping (_ host: String, _ port: Int) -> Void) {
        self.onPort = onPort
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.consume(d)
        }
        try p.run()
        process = p
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let (host, port) = Self.parse(line) { onPort(host, port) }
        }
    }

    static func parse(_ line: String) -> (String, Int)? {
        let r = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: r),
              let h = Range(m.range(at: 1), in: line), let p = Range(m.range(at: 2), in: line),
              let port = Int(line[p]) else { return nil }
        return (String(line[h]), port)
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    /// The most recent tunnel port in the recent system log, used to seed the first window.
    static func lastLoggedPort() -> Int? {
        guard let r = try? Shell.run("/usr/bin/log", ["show", "--last", "2h", "--style", "compact", "--predicate", predicate], timeout: 20) else { return nil }
        return r.stdout.split(separator: "\n").reversed().lazy.compactMap { parse(String($0))?.1 }.first
    }
}
