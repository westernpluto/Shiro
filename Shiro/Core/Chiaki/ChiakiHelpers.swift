import Foundation

/// Reads a NUL-terminated C string out of a fixed-size imported C array (tuple).
func stringFromCTuple<T>(_ tuple: T) -> String {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { raw -> String in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}

/// Copies a fixed-size imported C array (tuple) into `Data`.
func dataFromCTuple<T>(_ tuple: T) -> Data {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { Data($0) }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        self = data
    }

    /// Calls `body` with a pointer to exactly `count` bytes (zero padded / truncated).
    func withFixedBytes<R>(count: Int, _ body: (UnsafePointer<UInt8>) -> R) -> R {
        var buf = [UInt8](repeating: 0, count: count)
        let n = Swift.min(count, self.count)
        if n > 0 { copyBytes(to: &buf, count: n) }
        return buf.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

extension ChiakiErrorCode {
    var message: String { String(cString: chiaki_error_string(self)) }
    var isSuccess: Bool { self == CHIAKI_ERR_SUCCESS }
}

enum ChiakiLib {
    private static var initialized = false

    static func initialize() {
        guard !initialized else { return }
        initialized = true
        let err = chiaki_lib_init()
        if err != CHIAKI_ERR_SUCCESS {
            ShiroLog.shared.error("chiaki_lib_init failed: \(err.message)")
        }
    }
}
