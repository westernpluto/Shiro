import SwiftUI
import Combine

/// App-wide navigation / session state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var session: StreamSession?
    @Published var alert: AppAlert?

    private var sessionObserver: AnyCancellable?

    func connect(_ entry: ConsoleEntry, preferInternet: Bool = false) {
        guard let console = entry.registered else { return }
        let route: ConnectRoute
        if !preferInternet, let address = entry.discovered?.address ?? console.address {
            route = .local(address: address)
        } else if PSNAuth.shared.isSignedIn,
                  let duid = entry.psn?.connectDuid ?? console.psnDuid.map({ console.isPS5 ? $0 : PSNDeviceList.ps4ConnectDuid }) {
            route = .psn(duid: duid)
        } else if let address = console.address {
            route = .local(address: address)
        } else {
            alert = AppAlert(title: "Console not found",
                             message: "\(console.nickname) isn't on this network. Sign in to PSN in Settings to play over the internet, or add its address manually.")
            return
        }
        start(ConnectRequest(console: console, route: route, isPS5: console.isPS5, nickname: console.nickname))
    }

    /// PIN-less registration: links this device using the PSN account, then streams.
    func autoRegister(_ entry: ConsoleEntry) {
        guard PSNAuth.shared.isSignedIn else {
            alert = AppAlert(title: "Sign in to PSN", message: "Automatic registration uses your PlayStation Network account. Sign in from Settings first.")
            return
        }
        let ps5 = entry.isPS5
        let duid: String
        if let p = entry.psn {
            guard p.remotePlayEnabled else {
                alert = AppAlert(title: "Remote Play is off",
                                 message: "Turn on Remote Play on \(p.name): Settings › System › Remote Play › Enable Remote Play. Then pull down to refresh.")
                return
            }
            duid = p.connectDuid
        } else if !ps5 {
            duid = PSNDeviceList.ps4ConnectDuid
        } else {
            alert = AppAlert(title: "Console not linked",
                             message: "This PS5 isn't linked to your PSN account for Remote Play. On the console enable Settings › System › Remote Play, and make sure you're signed in with the same account — or register with a PIN instead.")
            return
        }
        start(ConnectRequest(console: nil, route: .psn(duid: duid), isPS5: ps5, nickname: entry.name,
                             autoRegister: true, autoRegisterAddress: entry.discovered?.address))
    }

    private func start(_ request: ConnectRequest) {
        session?.stop()
        let s = StreamSession(request: request)
        session = s
        sessionObserver = s.$phase.sink { [weak self, weak s] phase in
            guard let self = self, let s = s else { return }
            if case .ended(let error) = phase {
                if let error = error {
                    self.alert = AppAlert(title: "Disconnected", message: error)
                }
                // Let the UI animate out before dropping the session.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.session === s { self.session = nil }
                }
            }
        }
        s.start()
    }

    func disconnect(sleep: Bool = false) {
        session?.stop(sleepConsole: sleep || AppSettings.shared.sleepOnDisconnect)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
