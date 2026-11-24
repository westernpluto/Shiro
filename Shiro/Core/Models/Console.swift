import Foundation

/// A console that has completed Remote Play registration with this device.
struct RegisteredConsole: Codable, Identifiable, Hashable {
    var id: String { mac.hexString }

    var nickname: String
    var mac: Data
    var target: UInt32
    var registKey: Data
    var rpKey: Data
    var lastAddress: String?
    var manualAddress: String?
    var psnDuid: String?
    var hostType: String?
    var registeredAt: Date = Date()

    var isPS5: Bool { target >= 1_000_000 }

    var chiakiTarget: ChiakiTarget { ChiakiTarget(rawValue: .init(truncatingIfNeeded: target)) }

    var address: String? { manualAddress ?? lastAddress }

    var modelName: String { ConsoleModel.name(hostType: hostType, isPS5: isPS5) }
}

/// A console seen on the local network by the discovery service.
struct DiscoveredConsole: Identifiable, Hashable {
    enum State: String { case ready, standby, unknown }

    var id: String { hostId.lowercased() }
    var hostId: String
    var name: String
    var address: String
    var state: State
    var isPS5: Bool
    var hostType: String
    var systemVersion: String
    var target: UInt32
    var runningAppName: String?
    var runningAppTitleId: String?
    var lastSeen: Date

    var macData: Data? { Data(hex: hostId) }
    var modelName: String { ConsoleModel.name(hostType: hostType, isPS5: isPS5) }
}

/// A console linked to the PSN account (for internet Remote Play / PIN-less registration).
struct PSNDevice: Identifiable, Hashable, Codable {
    var id: String { duid }
    var duid: String
    var name: String
    var isPS5: Bool
    var remotePlayEnabled: Bool
}

enum ConsoleModel {
    static func name(hostType: String?, isPS5: Bool) -> String {
        let t = (hostType ?? "").uppercased()
        if t.contains("PRO") { return isPS5 ? "PS5 Pro" : "PS4 Pro" }
        return isPS5 ? "PlayStation 5" : "PlayStation 4"
    }
}

/// Unified row for the console list.
struct ConsoleEntry: Identifiable, Hashable {
    var id: String
    var registered: RegisteredConsole?
    var discovered: DiscoveredConsole?
    var psn: PSNDevice?

    var name: String { registered?.nickname ?? discovered?.name ?? psn?.name ?? "Console" }
    var isPS5: Bool { registered?.isPS5 ?? discovered?.isPS5 ?? psn?.isPS5 ?? true }
    var isRegistered: Bool { registered != nil }
    var isLocal: Bool { discovered != nil }
    var isAvailableRemotely: Bool { psn?.remotePlayEnabled == true && registered != nil }
    var state: DiscoveredConsole.State { discovered?.state ?? .unknown }
    var modelName: String {
        if let d = discovered { return d.modelName }
        if let r = registered { return r.modelName }
        return isPS5 ? "PlayStation 5" : "PlayStation 4"
    }
}
