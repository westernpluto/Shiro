import Foundation
import Combine

/// Single source of truth for consoles: registered (persisted in the
/// Keychain), discovered on the LAN, and linked to the PSN account.
@MainActor
final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()

    @Published private(set) var registered: [RegisteredConsole] = []
    @Published private(set) var discovered: [String: DiscoveredConsole] = [:]
    @Published private(set) var psnDevices: [PSNDevice] = []
    @Published private(set) var manualHosts: [String] = []
    @Published private(set) var refreshingPSN = false
    @Published var lastPSNError: String?

    private let discovery = DiscoveryService()
    private static let registeredKey = "consoles.registered"
    private static let manualKey = "consoles.manual"

    private init() {
        registered = Keychain.codable([RegisteredConsole].self, for: Self.registeredKey) ?? []
        manualHosts = UserDefaults.standard.stringArray(forKey: Self.manualKey) ?? []
        discovery.onUpdate = { [weak self] hosts in
            Task { @MainActor in self?.apply(discovered: hosts) }
        }
    }

    // MARK: Discovery

    func startDiscovery() {
        discovery.start(extraHosts: extraHosts)
    }

    func stopDiscovery() {
        discovery.stop()
    }

    private var extraHosts: [String] {
        Array(Set(manualHosts + registered.compactMap { $0.address }))
    }

    private func apply(discovered hosts: [DiscoveredConsole]) {
        var map: [String: DiscoveredConsole] = [:]
        for h in hosts { map[h.id] = h }
        if map != discovered { discovered = map }
        // Keep the last known address of registered consoles up to date.
        var changed = false
        for (i, r) in registered.enumerated() {
            if let d = map[r.id], r.lastAddress != d.address || (r.hostType ?? "") != d.hostType {
                registered[i].lastAddress = d.address
                registered[i].hostType = d.hostType
                changed = true
            }
        }
        if changed { saveRegistered() }
    }

    // MARK: Manual hosts

    func addManualHost(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !manualHosts.contains(h) else { return }
        manualHosts.append(h)
        UserDefaults.standard.set(manualHosts, forKey: Self.manualKey)
        discovery.updateExtraHosts(extraHosts)
    }

    func removeManualHost(_ host: String) {
        manualHosts.removeAll { $0 == host }
        UserDefaults.standard.set(manualHosts, forKey: Self.manualKey)
        discovery.updateExtraHosts(extraHosts)
    }

    // MARK: Registered consoles

    func addRegistered(_ host: ShiroRegisteredHost, address: String?, psnDuid: String? = nil) {
        let h = host
        let mac = dataFromCTuple(h.mac)
        let nickname = stringFromCTuple(h.nickname)
        let console = RegisteredConsole(
            nickname: nickname.isEmpty ? "PlayStation" : nickname,
            mac: mac,
            target: UInt32(truncatingIfNeeded: h.target.rawValue),
            registKey: dataFromCTuple(h.regist_key),
            rpKey: dataFromCTuple(h.rp_key),
            lastAddress: address,
            manualAddress: nil,
            psnDuid: psnDuid,
            hostType: discovered[mac.hexString]?.hostType)
        registered.removeAll { $0.id == console.id }
        registered.append(console)
        saveRegistered()
        discovery.updateExtraHosts(extraHosts)
        ShiroLog.shared.info("Registered \(console.nickname) (\(console.modelName))")
    }

    func update(_ console: RegisteredConsole) {
        guard let i = registered.firstIndex(where: { $0.id == console.id }) else { return }
        registered[i] = console
        saveRegistered()
        discovery.updateExtraHosts(extraHosts)
    }

    func remove(_ console: RegisteredConsole) {
        registered.removeAll { $0.id == console.id }
        saveRegistered()
    }

    private func saveRegistered() {
        Keychain.setCodable(registered, for: Self.registeredKey)
    }

    // MARK: PSN

    func refreshPSNDevices() async {
        guard PSNAuth.shared.isSignedIn else { psnDevices = []; return }
        refreshingPSN = true
        defer { refreshingPSN = false }
        do {
            let token = try await PSNAuth.shared.validAccessToken()
            let devices = await Task.detached(priority: .userInitiated) { () -> [PSNDevice] in
                var out: [PSNDevice] = []
                var buf = [ShiroPsnDevice](repeating: ShiroPsnDevice(), count: 16)
                var err = CHIAKI_ERR_SUCCESS
                for attempt in 0..<3 {
                    let n = token.withCString { t in
                        buf.withUnsafeMutableBufferPointer { b in
                            shiro_psn_list_devices(t, true, b.baseAddress, b.count, ShiroLog.shared.pointer, &err)
                        }
                    }
                    if err == CHIAKI_ERR_SUCCESS {
                        for i in 0..<Int(n) {
                            let d = buf[i]
                            out.append(PSNDevice(duid: dataFromCTuple(d.duid).hexString,
                                                 name: stringFromCTuple(d.name),
                                                 isPS5: d.ps5,
                                                 remotePlayEnabled: d.remoteplay_enabled))
                        }
                        break
                    }
                    ShiroLog.shared.warn("PSN device list attempt \(attempt + 1) failed: \(err.message)")
                }
                return out
            }.value
            var all = devices
            // PS4: Sony only allows Remote Play over the internet to the account's primary PS4.
            if registered.contains(where: { !$0.isPS5 }) {
                all.append(PSNDevice(duid: Data(repeating: 0x41, count: 32).hexString,
                                     name: "Primary PS4", isPS5: false, remotePlayEnabled: true))
            }
            psnDevices = all
            lastPSNError = nil
            linkPSNDevices()
        } catch {
            lastPSNError = error.localizedDescription
        }
    }

    /// Associates PSN devices with registered consoles by nickname.
    private func linkPSNDevices() {
        var changed = false
        for (i, r) in registered.enumerated() where r.psnDuid == nil {
            if let d = psnDevice(forNickname: r.nickname, ps5: r.isPS5) {
                registered[i].psnDuid = d.duid
                changed = true
            }
        }
        if changed { saveRegistered() }
    }

    func psnDevice(forNickname name: String, ps5: Bool) -> PSNDevice? {
        if !ps5 { return psnDevices.first { !$0.isPS5 } }
        return psnDevices.first { $0.isPS5 && $0.name == name }
    }

    // MARK: Merged list

    var entries: [ConsoleEntry] {
        var out: [ConsoleEntry] = []
        var used = Set<String>()
        for r in registered.sorted(by: { $0.nickname < $1.nickname }) {
            let psn = r.psnDuid.flatMap { duid in psnDevices.first { $0.duid == duid } }
                ?? psnDevice(forNickname: r.nickname, ps5: r.isPS5)
            out.append(ConsoleEntry(id: r.id, registered: r, discovered: discovered[r.id], psn: psn))
            used.insert(r.id)
            if let p = psn { used.insert(p.duid) }
        }
        for d in discovered.values.sorted(by: { $0.name < $1.name }) where !used.contains(d.id) {
            let psn = d.isPS5 ? psnDevice(forNickname: d.name, ps5: true) : nil
            out.append(ConsoleEntry(id: d.id, registered: nil, discovered: d, psn: psn))
            if let p = psn { used.insert(p.duid) }
        }
        return out
    }
}
