import Foundation
import Network

/// Finds PS4 / PS5 consoles on the local network.
///
/// iOS blocks UDP broadcast without Apple's restricted multicast entitlement,
/// so besides the broadcast ping we sweep every address of the local subnet
/// with unicast discovery packets (which only needs Local Network permission).
final class DiscoveryService {
    var onUpdate: (([DiscoveredConsole]) -> Void)?

    private var service: UnsafeMutablePointer<ChiakiDiscoveryService>?
    private let queue = DispatchQueue(label: "shiro.discovery")
    private var monitor: NWPathMonitor?
    private var extraHosts: [String] = []
    private var running = false

    func start(extraHosts: [String]) {
        queue.async {
            self.extraHosts = extraHosts
            self.running = true
            self.restartLocked()
            if self.monitor == nil {
                let m = NWPathMonitor()
                m.pathUpdateHandler = { [weak self] path in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.running, path.status == .satisfied else { return }
                        self.restartLocked()
                    }
                }
                m.start(queue: self.queue)
                self.monitor = m
            }
        }
    }

    func updateExtraHosts(_ hosts: [String]) {
        queue.async {
            guard hosts != self.extraHosts else { return }
            self.extraHosts = hosts
            if self.running { self.restartLocked() }
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.monitor?.cancel()
            self.monitor = nil
            self.stopLocked()
        }
    }

    private func stopLocked() {
        currentAddresses = []
        if let s = service {
            chiaki_discovery_service_fini(s)
            s.deallocate()
            service = nil
        }
    }

    private var currentAddresses: [UInt32] = []
    private var loggedNoNetwork = false

    private func restartLocked() {
        let interfaces = NetworkInterfaces.ipv4Interfaces()
        var addrs: [UInt32] = []
        for iface in interfaces {
            addrs.append(contentsOf: iface.sweepAddresses())
        }
        for h in extraHosts {
            if let a = NetworkInterfaces.parse(h) { addrs.append(a) }
        }
        var seen = Set<UInt32>()
        let unique = addrs.filter { seen.insert($0).inserted }.map { $0.bigEndian }

        // Network path updates fire often; only restart when the targets change.
        if service != nil && unique == currentAddresses { return }
        stopLocked()
        currentAddresses = unique
        if unique.isEmpty {
            if !loggedNoNetwork {
                loggedNoNetwork = true
                ShiroLog.shared.info("Local discovery paused: no Wi-Fi or Ethernet network (consoles on your PSN account are still listed)")
            }
            onUpdate?([])
            return
        }
        loggedNoNetwork = false
        let s = UnsafeMutablePointer<ChiakiDiscoveryService>.allocate(capacity: 1)
        let user = Unmanaged.passUnretained(self).toOpaque()
        let err = unique.withUnsafeBufferPointer { buf in
            shiro_discovery_service_start(s, buf.baseAddress, buf.count, 1500, { hosts, count, user in
                guard let user = user else { return }
                let me = Unmanaged<DiscoveryService>.fromOpaque(user).takeUnretainedValue()
                me.handle(hosts: hosts, count: Int(count))
            }, user, ShiroLog.shared.pointer)
        }
        if err != CHIAKI_ERR_SUCCESS {
            ShiroLog.shared.error("Discovery failed to start: \(err.message)")
            s.deallocate()
            return
        }
        service = s
        ShiroLog.shared.info("Discovery sweeping \(unique.count) addresses on \(interfaces.map(\.name).joined(separator: ", "))")
    }

    private func handle(hosts: UnsafeMutablePointer<ChiakiDiscoveryHost>?, count: Int) {
        var result: [DiscoveredConsole] = []
        if let hosts = hosts {
            for i in 0..<count {
                let h = hosts.advanced(by: i)
                func str(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
                guard let addr = str(h.pointee.host_addr), let hostId = str(h.pointee.host_id) else { continue }
                let state: DiscoveredConsole.State
                switch h.pointee.state {
                case CHIAKI_DISCOVERY_HOST_STATE_READY: state = .ready
                case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: state = .standby
                default: state = .unknown
                }
                let ps5 = chiaki_discovery_host_is_ps5(h)
                let target = chiaki_discovery_host_system_version_target(h)
                result.append(DiscoveredConsole(
                    hostId: hostId,
                    name: str(h.pointee.host_name) ?? "PlayStation",
                    address: addr,
                    state: state,
                    isPS5: ps5,
                    hostType: str(h.pointee.host_type) ?? "",
                    systemVersion: str(h.pointee.system_version) ?? "",
                    target: UInt32(truncatingIfNeeded: target.rawValue),
                    runningAppName: str(h.pointee.running_app_name),
                    runningAppTitleId: str(h.pointee.running_app_titleid),
                    lastSeen: Date()))
            }
        }
        onUpdate?(result)
    }

    /// Sends a wake-up packet to a registered console in standby.
    static func wake(_ console: RegisteredConsole, address: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let err = console.registKey.withFixedBytes(count: 16) { key in
                shiro_wakeup(ShiroLog.shared.pointer, address, key, console.isPS5)
            }
            if err != CHIAKI_ERR_SUCCESS {
                ShiroLog.shared.warn("Wake-up failed: \(err.message)")
            }
        }
    }
}
