import SwiftUI

struct ConsolesView: View {
    @EnvironmentObject private var store: ConsoleStore
    @EnvironmentObject private var psn: PSNAuth
    @EnvironmentObject private var model: AppModel

    @State private var registering: ConsoleEntry?
    @State private var addingHost = false
    @State private var newHost = ""
    @State private var editing: RegisteredConsole?
    @State private var showPSNLogin = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !psn.isSignedIn {
                        PSNBanner { showPSNLogin = true }
                    } else if let error = store.lastPSNError {
                        PSNErrorBanner(message: error) {
                            Task { await store.refreshPSNDevices() }
                        }
                    }
                    if store.refreshingPSN && store.psnDevices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading consoles from your PSN account…").foregroundStyle(.secondary)
                        }
                    }
                    let entries = store.entries
                    if entries.isEmpty {
                        EmptyConsolesView()
                    } else {
                        LazyVGrid(columns: columns(for: proxy.size.width), spacing: 16) {
                            ForEach(entries) { entry in
                                ConsoleCard(entry: entry)
                                    .onTapGesture { primaryAction(entry) }
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                    }
                }
                .padding()
            }
            .refreshable {
                store.startDiscovery()
                await store.refreshPSNDevices()
            }
        }
        .navigationTitle("Consoles")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { addingHost = true } label: {
                    Label("Add console by address", systemImage: "plus")
                }
                Button {
                    store.startDiscovery()
                    Task { await store.refreshPSNDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $registering) { entry in
            RegisterSheet(entry: entry)
        }
        .sheet(item: $editing) { console in
            EditConsoleSheet(console: console)
        }
        .sheet(isPresented: $showPSNLogin) {
            PSNLoginView()
        }
        .alert("Add console", isPresented: $addingHost) {
            TextField("IP address or hostname", text: $newHost)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Add") { store.addManualHost(newHost); newHost = "" }
            Button("Cancel", role: .cancel) { newHost = "" }
        } message: {
            Text("Use this for consoles on another subnet or reachable through a VPN.")
        }
    }

    /// HIG: prefer an even number of grid columns so content divides cleanly
    /// across iPhone Duo's two halves.
    private func columns(for width: CGFloat) -> [GridItem] {
        var n = max(1, Int(width / 300))
        if n > 1 && n % 2 == 1 { n -= 1 }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: n)
    }

    private func primaryAction(_ entry: ConsoleEntry) {
        if entry.isRegistered {
            model.connect(entry)
        } else {
            registering = entry
        }
    }

    @ViewBuilder
    private func menu(for entry: ConsoleEntry) -> some View {
        if let r = entry.registered {
            Button { model.connect(entry) } label: { Label("Play", systemImage: "play.fill") }
            if entry.psn != nil && psn.isSignedIn {
                Button { model.connect(entry, preferInternet: true) } label: { Label("Play over the internet", systemImage: "globe") }
            }
            if let addr = entry.discovered?.address ?? r.address, entry.state != .ready {
                Button { DiscoveryService.wake(r, address: addr) } label: { Label("Wake", systemImage: "power") }
            }
            Button { editing = r } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { store.remove(r) } label: { Label("Forget console", systemImage: "trash") }
        } else {
            Button { registering = entry } label: { Label("Register", systemImage: "link") }
        }
    }
}

struct ConsoleCard: View {
    let entry: ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: entry.isPS5 ? "playstation.logo" : "gamecontroller.fill")
                    .font(.title2)
                Spacer()
                StatusPill(entry: entry)
            }
            Spacer(minLength: 0)
            Text(entry.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(entry.modelName)
                if let app = entry.discovered?.runningAppName, !app.isEmpty {
                    Text("·")
                    Text(app).lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: entry.isPS5
                                     ? [Color(red: 0.16, green: 0.22, blue: 0.48), Color(red: 0.08, green: 0.1, blue: 0.24)]
                                     : [Color(red: 0.1, green: 0.18, blue: 0.36), Color(red: 0.05, green: 0.08, blue: 0.18)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct StatusPill: View {
    let entry: ConsoleEntry

    var body: some View {
        let (text, color): (String, Color) = {
            if let p = entry.psn, !p.remotePlayEnabled { return ("Remote Play off", .orange) }
            if !entry.isRegistered {
                return entry.isLocal ? ("Tap to set up", .orange) : ("On your account", .blue)
            }
            switch entry.state {
            case .ready: return ("Ready", .green)
            case .standby: return ("Rest mode", .yellow)
            case .unknown: return entry.isAvailableRemotely ? ("Internet", .blue) : ("Offline", .gray)
            }
        }()
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PSNErrorBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load consoles from PSN").font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer()
            Button("Retry", action: retry).buttonStyle(.bordered)
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PSNBanner: View {
    let action: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to PlayStation Network").font(.headline)
                Text("Needed to register consoles automatically and to play over the internet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign in", action: action).buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EmptyConsolesView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .symbolEffect(.pulse)
            Text("Looking for consoles…").font(.title3.weight(.semibold))
            Text("Make sure your PS4 or PS5 is on (or in rest mode with network access enabled) and on the same Wi-Fi network. Remote Play must be enabled on the console.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

struct EditConsoleSheet: View {
    @State var console: RegisteredConsole
    @EnvironmentObject private var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Nickname", text: $console.nickname)
                }
                Section {
                    TextField("Automatic", text: Binding(get: { console.manualAddress ?? "" },
                                                         set: { console.manualAddress = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Leave empty to use the address found on the network (\(console.lastAddress ?? "none yet")). Set a hostname or IP to reach the console through a VPN or port forwarding.")
                }
                Section("Details") {
                    LabeledContent("Model", value: console.modelName)
                    LabeledContent("MAC", value: console.mac.map { String(format: "%02X", $0) }.joined(separator: ":"))
                    LabeledContent("Internet play", value: console.psnDuid == nil ? "Not linked" : "Linked to PSN")
                }
            }
            .navigationTitle(console.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { store.update(console); dismiss() } label: { Label("Save", systemImage: "checkmark") }
                }
            }
        }
    }
}
