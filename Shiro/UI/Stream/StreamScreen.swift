import SwiftUI

/// Full-screen streaming experience.
///
/// iPhone Duo behaviour (per the HIG "Designing for iPhone Duo" guidance for games):
/// * Playable in every pose: outer display, inner display flat, book and laptop poses.
/// * Fills the screen as the pose changes instead of re-layouting controls.
/// * When the inner display is partially folded, the video takes one half and
///   the other half becomes a touchpad / control deck (system `ArrangementView`).
/// * Letterbox bars on the near-square inner display are filled with an
///   ambient, blurred extension of the picture rather than left black.
/// * Interactive overlays stay inside the safe area so they never sit under
///   the camera housings or the fold.
struct StreamScreen: View {
    @ObservedObject var session: StreamSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var input: InputManager
    @EnvironmentObject private var display: DisplayManager
    @EnvironmentObject private var model: AppModel

    @State private var showMenu = false
    @State private var pin = ""
    @State private var keyboard = ""

    private var showTouchControls: Bool {
        settings.touchControls && input.controllers.isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if display.routesVideoExternally {
                // Video is on the external display; the whole phone is the companion.
                CompanionPanel(session: session, showsGamepad: showTouchControls)
            } else {
                FoldArrangement(splitWhenFolded: settings.foldedSplit) {
                    videoWithOverlays
                } secondary: {
                    CompanionPanel(session: session, showsGamepad: showTouchControls)
                }
                .ignoresSafeArea()
            }
            phaseOverlay
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showMenu) {
            StreamMenu(session: session)
                .presentationDetents([.medium, .large])
        }
        .alert("Console PIN", isPresented: Binding(get: { session.pinRequest != nil }, set: { if !$0 && session.pinRequest != nil { session.stop() } })) {
            TextField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Connect") { session.submitPin(pin); pin = "" }
            Button("Cancel", role: .cancel) { session.stop() }
        } message: {
            Text(session.pinRequest == true ? "Incorrect PIN — try again." : "Enter the Remote Play login PIN set on this console.")
        }
        .alert("Keyboard", isPresented: Binding(get: { session.keyboardText != nil }, set: { _ in })) {
            TextField("Text", text: $keyboard)
            Button("Send") { session.submitKeyboard(text: keyboard, accept: true); keyboard = "" }
            Button("Cancel", role: .cancel) { session.submitKeyboard(text: "", accept: false) }
        }
        .onChange(of: session.keyboardText) { _, t in if let t = t { keyboard = t } }
    }

    private var videoWithOverlays: some View {
        ZStack {
            VideoSurface(renderer: session.video, fill: settings.videoFill, ambient: settings.ambientFill)
                .ignoresSafeArea()
            if showTouchControls && session.phase == .streaming {
                TouchGamepad(opacity: settings.touchControlsOpacity)
            }
            hud
        }
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                if settings.showStats { StatsOverlay(stats: session.stats) }
                Spacer()
                Button {
                    showMenu = true
                } label: {
                    Label("Stream menu", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .opacity(0.75)
            }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch session.phase {
        case .idle, .waking, .connecting:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text(phaseText).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) { session.stop() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        default:
            EmptyView()
        }
    }

    private var phaseText: String {
        switch session.phase {
        case .waking: return "Waking \(session.request.nickname)…"
        case .connecting(let s): return s
        default: return "Preparing…"
        }
    }
}

struct StatsOverlay: View {
    let stats: StreamStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.width)×\(stats.height) \(stats.codec)\(stats.hdr ? " HDR" : "")")
            Text(String(format: "%.0f fps · %.1f / %.0f Mbps", stats.fps, stats.measuredMbps, Double(stats.requestedKbps) / 1000))
            Text(String(format: "RTT %.0f ms · audio %.0f ms", stats.rttMs, stats.audioBufferMs))
            Text("lost \(stats.framesLost) · dec err \(stats.decodeErrors) · underruns \(stats.audioUnderruns)")
            if stats.isInternet { Text("via PSN (internet)") }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Stream menu sheet: console shortcuts, mic, layout options and disconnect.
struct StreamMenu: View {
    @ObservedObject var session: StreamSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var input: InputManager
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Console") {
                    Button { input.tap(CHIAKI_CONTROLLER_BUTTON_PS); dismiss() } label: { Label("PS button", systemImage: "house.fill") }
                    Button { input.tap(CHIAKI_CONTROLLER_BUTTON_SHARE); dismiss() } label: { Label("Create / Share", systemImage: "square.and.arrow.up") }
                    Button { input.tap(CHIAKI_CONTROLLER_BUTTON_OPTIONS); dismiss() } label: { Label("Options", systemImage: "line.3.horizontal") }
                    Button { session.toggleMicrophone() } label: {
                        Label(session.micActive ? "Mute microphone" : "Unmute microphone",
                              systemImage: session.micActive ? "mic.slash.fill" : "mic.fill")
                    }
                }
                Section("Display") {
                    Picker("Video", selection: $settings.videoFill) {
                        ForEach(VideoFill.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Ambient fill for letterbox", isOn: $settings.ambientFill)
                    Toggle("Split stream at the fold", isOn: $settings.foldedSplit)
                    Toggle("Show statistics", isOn: $settings.showStats)
                    Toggle("Touch controls", isOn: $settings.touchControls)
                }
                Section("Controllers") {
                    Picker("Couch co-op", selection: $settings.coopMode) {
                        ForEach(CoopMode.allCases) { Text($0.label).tag($0) }
                    }
                    if input.controllers.isEmpty {
                        Text("No controllers connected").foregroundStyle(.secondary)
                    }
                    ForEach(input.controllers) { c in
                        HStack {
                            Label("Player \(c.player) · \(c.name)", systemImage: "gamecontroller.fill")
                            Spacer()
                            if c.isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) { dismiss(); model.disconnect() } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) { dismiss(); model.disconnect(sleep: true) } label: {
                        Label("Put console in rest mode & disconnect", systemImage: "moon.zzz")
                    }
                }
            }
            .navigationTitle(session.serverNickname ?? session.request.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
        }
    }
}

/// Content of the external display window.
struct ExternalDisplayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = model.session, settings.useExternalDisplay {
                VideoSurface(renderer: session.video, fill: settings.videoFill, ambient: settings.ambientFill)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 72))
                    Text("Shiro").font(.largeTitle.bold())
                    Text("Start a stream on your iPhone to play here.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }
}
