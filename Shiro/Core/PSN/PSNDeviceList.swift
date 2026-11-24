import Foundation

/// Lists the consoles linked to the signed-in PSN account — the same list the
/// official Remote Play app shows right after sign-in, whether or not the
/// console is on the local network.
enum PSNDeviceList {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// PS4 consoles are reached through PSN with this fixed placeholder id;
    /// Sony only allows internet Remote Play to the account's primary PS4.
    static let ps4ConnectDuid = Data(repeating: 0x41, count: 32).hexString

    static func fetch(token: String) async throws -> [PSNDevice] {
        // Sony's device list only covers PS5 (PS4 requests return HTTP 400); PS4
        // internet play goes through the account's primary PS4 instead.
        let devices: [PSNDevice]
        do {
            devices = try await fetch(platform: "PS5", token: token)
        } catch {
            ShiroLog.shared.warn("PSN device list failed: \(error.localizedDescription)")
            throw Failure(message: "Couldn't load your consoles from PSN: \(error.localizedDescription)")
        }
        ShiroLog.shared.info("PSN account has \(devices.count) console(s): " +
            devices.map { "\($0.name) [\($0.isPS5 ? "PS5" : "PS4")\($0.remotePlayEnabled ? "" : ", Remote Play off")]" }.joined(separator: ", "))
        return devices
    }

    private static func fetch(platform: String, token: String) async throws -> [PSNDevice] {
        var out: [PSNDevice] = []
        var offset = 0
        let pageSize = 10
        while offset < 100 {
            var comps = URLComponents(string: "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients")!
            comps.queryItems = [
                .init(name: "platform", value: platform),
                .init(name: "includeFields", value: "device"),
                .init(name: "limit", value: String(pageSize)),
                .init(name: "offset", value: String(offset)),
            ]
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 15
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "Accept-Language")

            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                if status == 401 || status == 403 {
                    throw Failure(message: "PSN rejected the sign-in (HTTP \(status)). Sign out and sign in again in Settings.")
                }
                throw Failure(message: "HTTP \(status) \(body)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(message: "Unexpected response")
            }
            let clients = json["clients"] as? [[String: Any]] ?? []
            for client in clients {
                // Be lenient: skip entries we don't understand instead of failing the whole list.
                guard let duid = client["duid"] as? String, !duid.isEmpty else { continue }
                let device = client["device"] as? [String: Any] ?? [:]
                let name = (device["name"] as? String)
                    ?? (client["name"] as? String)
                    ?? (platform == "PS5" ? "PS5" : "PS4")
                let features = device["enabledFeatures"] as? [String] ?? []
                out.append(PSNDevice(duid: duid.lowercased(), name: name, isPS5: platform == "PS5",
                                     remotePlayEnabled: features.contains("remotePlay")))
            }
            if clients.count < pageSize { break }
            offset += pageSize
        }
        return out
    }
}

extension PSNDevice {
    /// The id used when connecting through PSN.
    var connectDuid: String { isPS5 ? duid : PSNDeviceList.ps4ConnectDuid }
}
