import Foundation
import Combine

struct PSNCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// 8-byte little-endian PSN account id (what consoles call "AccountID").
    var accountId: Data
    var userId: String
    /// Scopes Sony actually granted (nil for sign-ins made by older builds).
    var grantedScope: String? = nil

    /// Internet Remote Play needs the push-notification and session scopes.
    var hasRemotePlayScopes: Bool {
        guard let g = grantedScope else { return false }
        return g.contains("pushNotification:webSocket.desktop.connect")
            && g.contains("sessionManager:remotePlaySession.system.update")
    }
}

enum PSNError: LocalizedError {
    case badRedirect, http(Int, String), decoding, notLoggedIn
    var errorDescription: String? {
        switch self {
        case .badRedirect: return "The PlayStation sign-in did not return an authorization code."
        case .http(let code, let body): return "PSN request failed (\(code)). \(body.prefix(200))"
        case .decoding: return "Unexpected response from PSN."
        case .notLoggedIn: return "Sign in to PlayStation Network first."
        }
    }
}

/// PlayStation Network sign-in, using the same OAuth client as Sony's own
/// Remote Play app. Tokens never leave the device (stored in the Keychain).
@MainActor
final class PSNAuth: ObservableObject {
    static let shared = PSNAuth()

    static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURL = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    private static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURL),
            .init(name: "scope", value: scope),
            .init(name: "request_locale", value: Locale.current.identifier.replacingOccurrences(of: "-", with: "_")),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return c.url!
    }

    @Published private(set) var credentials: PSNCredentials?
    var isSignedIn: Bool { credentials != nil }

    private static let keychainKey = "psn.credentials"

    private init() {
        let stored = Keychain.codable(PSNCredentials.self, for: Self.keychainKey)
        if let c = stored, !c.hasRemotePlayScopes {
            // Older builds sent the scope list in a form Sony only partly
            // understood, so those tokens can't open the Remote Play push
            // channel (HTTP 403). Ask the user to sign in again.
            ShiroLog.shared.warn("Stored PSN sign-in lacks Remote Play permissions (granted: \(c.grantedScope ?? "unknown")); signing out so you can sign in again")
            Keychain.setCodable(Optional<PSNCredentials>.none, for: Self.keychainKey)
            credentials = nil
        } else {
            credentials = stored
        }
    }

    /// Form body with the scope list sent exactly as Sony's own client does
    /// (literal spaces — Sony does not decode '+' as a space here).
    private static func tokenBody(_ fields: [(String, String)]) -> String {
        fields.map { key, value in
            key == "scope" ? "\(key)=\(value)" : "\(key)=\(value.formEncoded)"
        }.joined(separator: "&")
    }

    /// Extracts the `code` parameter from the redirect URL (or from text the user pasted).
    static func code(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed),
           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        // Allow pasting just the code.
        if !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("/") { return trimmed }
        return nil
    }

    func signIn(code: String) async throws {
        let tokens = try await requestToken(body: Self.tokenBody([
            ("grant_type", "authorization_code"), ("code", code),
            ("scope", Self.scope), ("redirect_uri", Self.redirectURL)]))
        let userId = try await fetchUserId(accessToken: tokens.access)
        guard let uid = UInt64(userId) else { throw PSNError.decoding }
        var le = uid.littleEndian
        let accountId = Data(bytes: &le, count: 8)
        let creds = PSNCredentials(accessToken: tokens.access, refreshToken: tokens.refresh,
                                   expiry: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)),
                                   accountId: accountId, userId: userId,
                                   grantedScope: tokens.scope ?? Self.scope)
        store(creds)
        ShiroLog.shared.info("Signed in to PSN (granted scopes: \(tokens.scope ?? "not reported"))")
        if !creds.hasRemotePlayScopes {
            ShiroLog.shared.warn("PSN did not grant the Remote Play scopes; internet play and automatic registration will not work")
        }
    }

    func signOut() {
        store(nil)
    }

    /// Returns a valid access token, refreshing it when it expires within a minute.
    func validAccessToken() async throws -> String {
        guard var creds = credentials else { throw PSNError.notLoggedIn }
        if creds.expiry.timeIntervalSinceNow > 60 { return creds.accessToken }
        let tokens = try await requestToken(body: Self.tokenBody([
            ("grant_type", "refresh_token"), ("refresh_token", creds.refreshToken),
            ("scope", Self.scope), ("redirect_uri", Self.redirectURL)]))
        creds.accessToken = tokens.access
        if let granted = tokens.scope { creds.grantedScope = granted }
        if !tokens.refresh.isEmpty { creds.refreshToken = tokens.refresh }
        creds.expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        store(creds)
        return creds.accessToken
    }

    private func store(_ creds: PSNCredentials?) {
        credentials = creds
        Keychain.setCodable(creds, for: Self.keychainKey)
    }

    private var basicAuth: String {
        "Basic " + Data("\(Self.clientId):\(Self.clientSecret)".utf8).base64EncodedString()
    }

    private func requestToken(body: String) async throws -> (access: String, refresh: String, expiresIn: Int, scope: String?) {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 400 || status == 401 { store(nil) }
            throw PSNError.http(status, String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw PSNError.decoding }
        let refresh = json["refresh_token"] as? String ?? ""
        let expires = (json["expires_in"] as? Int) ?? Int((json["expires_in"] as? Double) ?? 3600)
        return (access, refresh, expires, json["scope"] as? String)
    }

    private func fetchUserId(accessToken: String) async throws -> String {
        var req = URLRequest(url: Self.tokenURL.appendingPathComponent(accessToken))
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PSNError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PSNError.decoding }
        if let s = json["user_id"] as? String { return s }
        if let n = json["user_id"] as? NSNumber { return n.stringValue }
        throw PSNError.decoding
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? self
    }
}
