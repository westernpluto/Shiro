import SwiftUI

@main
struct ShiroApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .environmentObject(ConsoleStore.shared)
                .environmentObject(PSNAuth.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(InputManager.shared)
                .environmentObject(DisplayManager.shared)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ConsoleStore.shared.startDiscovery()
                Task { await ConsoleStore.shared.refreshPSNDevices() }
            case .background:
                ConsoleStore.shared.stopDiscovery()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            HomeView()
            if let session = model.session {
                StreamScreen(session: session)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.session != nil)
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}
