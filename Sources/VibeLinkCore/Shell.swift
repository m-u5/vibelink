import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ShellError: Error, CustomStringConvertible {
    case notFound(String)
    case timedOut(String)
    case failed(String, Int32, String)

    public var description: String {
        switch self {
        case .notFound(let p): return "command not found: \(p)"
        case .timedOut(let p): return "command timed out: \(p)"
        case .failed(let p, let s, let e): return "\(p) exited \(s): \(e.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

public enum Shell {
    /// Runs a command to completion, killing it after `timeout`.
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ShellError.notFound(path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw ShellError.timedOut(([path] + args).joined(separator: " "))
        }
        group.wait()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    /// First existing executable among candidates.
    public static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
