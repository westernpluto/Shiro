import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case consoles, controllers, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .consoles: return "Consoles"
        case .controllers: return "Controllers"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .consoles: return "play.tv"
        case .controllers: return "gamecontroller"
        case .settings: return "gearshape"
        }
    }
}

/// Top-level navigation. `NavigationSplitView` collapses to a single column on
/// iPhone Duo's compact outer display and expands to sidebar + content on the
/// regular-width inner display, with the system placing bars vertically.
struct HomeView: View {
    @State private var selection: SidebarItem? = .consoles
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                }
            }
            .navigationTitle("Shiro")
        } detail: {
            NavigationStack {
                switch selection ?? .consoles {
                case .consoles: ConsolesView()
                case .controllers: ControllersView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
