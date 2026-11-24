import Foundation
import os

/// Owns a `ChiakiLog` C struct and forwards chiaki-ng log lines to os_log and
/// an in-memory ring buffer the user can export from Settings.
final class ShiroLog {
    static let shared = ShiroLog()

    let pointer: UnsafeMutablePointer<ChiakiLog>
    private let logger = Logger(subsystem: "io.github.westernpluto.shiro", category: "chiaki")
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 4000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var verbose: Bool = false {
        didSet {
            chiaki_log_set_level(pointer, verbose ? 0x1F : Self.defaultMask)
        }
    }

    private static let defaultMask: UInt32 =
        UInt32(CHIAKI_LOG_INFO.rawValue | CHIAKI_LOG_WARNING.rawValue | CHIAKI_LOG_ERROR.rawValue)

    private init() {
        pointer = .allocate(capacity: 1)
        chiaki_log_init(pointer, Self.defaultMask, { level, msg, user in
            guard let msg = msg, let user = user else { return }
            let me = Unmanaged<ShiroLog>.fromOpaque(user).takeUnretainedValue()
            me.append(level: level, String(cString: msg))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func info(_ message: String) { append(level: CHIAKI_LOG_INFO, message) }
    func warn(_ message: String) { append(level: CHIAKI_LOG_WARNING, message) }
    func error(_ message: String) { append(level: CHIAKI_LOG_ERROR, message) }

    private func append(level: ChiakiLogLevel, _ message: String) {
        let c: String
        switch level {
        case CHIAKI_LOG_ERROR: c = "E"; logger.error("\(message, privacy: .public)")
        case CHIAKI_LOG_WARNING: c = "W"; logger.warning("\(message, privacy: .public)")
        case CHIAKI_LOG_INFO: c = "I"; logger.info("\(message, privacy: .public)")
        default: c = "D"; logger.debug("\(message, privacy: .public)")
        }
        let line = "\(formatter.string(from: Date())) [\(c)] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    /// Writes the log to Documents so it is reachable from the Files app.
    func export() -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("shiro-log.txt")
        do {
            try snapshot().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
