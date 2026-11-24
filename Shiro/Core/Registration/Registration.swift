import Foundation

enum RegistrationError: LocalizedError {
    case needsPSN, startFailed(String), failed, canceled, timeout
    var errorDescription: String? {
        switch self {
        case .needsPSN: return "Sign in to PlayStation Network first — your console needs your PSN account ID to register this device."
        case .startFailed(let m): return "Could not start registration: \(m)"
        case .failed: return "Registration failed. Check the PIN and make sure the console shows the pairing screen."
        case .canceled: return "Registration canceled."
        case .timeout: return "The console did not answer. Make sure it is on and on the same network."
        }
    }
}

/// Classic PIN-based Remote Play registration over the LAN.
final class PinRegistration {
    private let regist = UnsafeMutablePointer<ChiakiRegist>.allocate(capacity: 1)
    private var continuation: CheckedContinuation<ShiroRegisteredHost, Error>?
    private var started = false
    private let lock = NSLock()

    deinit {
        // The last reference may be dropped on chiaki's registration thread;
        // joining it from itself would deadlock, so finish on another queue.
        let r = regist
        let wasStarted = started
        DispatchQueue.global(qos: .utility).async {
            if wasStarted { chiaki_regist_fini(r) }
            r.deallocate()
        }
    }

    func register(address: String, target: UInt32, accountId: Data, pin: UInt32) async throws -> ShiroRegisteredHost {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShiroRegisteredHost, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            let user = Unmanaged.passRetained(self).toOpaque()
            let err: ChiakiErrorCode = accountId.withFixedBytes(count: 8) { acc in
                address.withCString { host in
                    shiro_regist_start(regist, ShiroLog.shared.pointer,
                                       ChiakiTarget(rawValue: .init(truncatingIfNeeded: target)),
                                       host, acc, pin, { event, user in
                        guard let user = user else { return }
                        let me = Unmanaged<PinRegistration>.fromOpaque(user).takeRetainedValue()
                        me.finish(event)
                    }, user)
                }
            }
            if err != CHIAKI_ERR_SUCCESS {
                Unmanaged<PinRegistration>.fromOpaque(user).release()
                resume(.failure(RegistrationError.startFailed(err.message)))
            } else {
                started = true
            }
        }
    }

    func cancel() {
        if started { chiaki_regist_stop(regist) }
    }

    private func finish(_ event: UnsafeMutablePointer<ChiakiRegistEvent>?) {
        guard let e = event?.pointee else { resume(.failure(RegistrationError.failed)); return }
        switch e.type {
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
            if let host = e.registered_host {
                var out = ShiroRegisteredHost()
                shiro_registered_host_flatten(host, &out)
                resume(.success(out))
            } else {
                resume(.failure(RegistrationError.failed))
            }
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
            resume(.failure(RegistrationError.canceled))
        default:
            resume(.failure(RegistrationError.failed))
        }
    }

    private func resume(_ result: Result<ShiroRegisteredHost, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
