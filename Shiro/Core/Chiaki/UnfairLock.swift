import os

/// A tiny real-time-safe lock (no allocation, no priority inversion on Darwin).
final class UnfairLock {
    private let l: os_unfair_lock_t

    init() {
        l = .allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
    }

    deinit {
        l.deinitialize(count: 1)
        l.deallocate()
    }

    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(l)
        defer { os_unfair_lock_unlock(l) }
        return try body()
    }
}
