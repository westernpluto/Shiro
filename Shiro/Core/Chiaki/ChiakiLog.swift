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
    private let maxLines = 8000
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

    // Discovery sweeps send hundreds of probes per round; failed probes to
    // addresses with nothing behind them are expected and would otherwise
    // flood the ring buffer and push out the lines that matter.
    private var suppressedDiscovery = 0
    private var lastDiscoveryError = ""
    private var lastDiscoverySummary = Date.distantPast

    private func isDiscoveryNoise(_ message: String) -> Bool {
        message.hasPrefix("Discovery failed to send") || message.hasPrefix("Discovery Service failed to send")
    }

    private func append(level: ChiakiLogLevel, _ message: String) {
        if isDiscoveryNoise(message) {
            lock.lock()
            suppressedDiscovery += 1
            if message.hasPrefix("Discovery failed to send:") { lastDiscoveryError = message }
            let due = Date().timeIntervalSince(lastDiscoverySummary) > 60
            let count = suppressedDiscovery
            let last = lastDiscoveryError
            if due {
                suppressedDiscovery = 0
                lastDiscoverySummary = Date()
            }
            lock.unlock()
            if due {
                appendLine(level: CHIAKI_LOG_INFO,
                           "Discovery: \(count) probe(s) got no answer in the last minute (normal for a network scan; last: \(last))")
            }
            return
        }
        appendLine(level: level, message)
    }

    private func appendLine(level: ChiakiLogLevel, _ message: String) {
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

    /// Writes the privacy-redacted log to Documents (reachable from the Files app).
    func export(redactingNames names: [String]) -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("shiro-log.txt")
        do {
            try Self.redact(snapshot(), names: names).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Redaction

    /// Removes personal details before a log is shared: console and account
    /// names, IP and MAC addresses, device / console ids, e-mail addresses and
    /// anything that looks like a token or key. Keeps whether an address was
    /// local or public, which is what matters for debugging.
    static func redact(_ text: String, names: [String]) -> String {
        var s = text

        // Known console names → stable placeholders.
        let uniqueNames = Array(Set(names.filter { $0.count >= 2 })).sorted { $0.count > $1.count }
        for (i, name) in uniqueNames.enumerated() {
            s = s.replacingOccurrences(of: name, with: "<console-\(i + 1)>", options: .caseInsensitive)
        }

        func replace(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }

        // Secrets first (so later patterns can't leave parts behind).
        replace(#"(?i)(bearer\s+|authorization:\s*\S+\s+|access_token["=:\s]+|refresh_token["=:\s]+|[?&]code=)[A-Za-z0-9._~+/=\-]+"#, "$1<redacted>")
        replace(#"[^\s@<>"']+@[^\s@<>"']+\.[A-Za-z]{2,}"#, "<email>")
        // MAC addresses, then IPv6 (needs 3+ colons so log timestamps survive).
        replace(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "<mac>")
        replace(#"\b(?:[0-9A-Fa-f]{0,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "<ipv6>")
        // Long hex ids (console ids, MACs without separators, session ids).
        replace(#"\b[0-9A-Fa-f]{12,}\b"#, "<id>")
        // Long base64 / token-like strings.
        replace(#"[A-Za-z0-9+/_\-]{32,}={0,2}"#, "<redacted>")

        // IPv4: keep local vs public classification.
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#) {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let a = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let b = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let local = a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 169 && b == 254)
                let cgnat = a == 100 && (64...127).contains(b)
                out += local ? "<lan-ip>" : (cgnat ? "<cgnat-ip>" : (a == 255 ? "<broadcast>" : "<public-ip>"))
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        return s
    }
}
