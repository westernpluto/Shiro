import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var psn: PSNAuth
    @EnvironmentObject private var store: ConsoleStore
    @EnvironmentObject private var display: DisplayManager
    @State private var showLogin = false

    var body: some View {
        Form {
            Section {
                if let c = psn.credentials {
                    LabeledContent("Account ID", value: c.accountId.base64EncodedString())
                    Button(role: .destructive) { psn.signOut() } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button { showLogin = true } label: {
                        Label("Sign in to PlayStation Network", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                if let e = store.lastPSNError { Text(e).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("PlayStation Network")
            } footer: {
                Text("Enables automatic (PIN-less) registration and Remote Play over the internet without port forwarding. Your sign-in stays on this device.")
            }

            Section {
                Picker("Resolution (home)", selection: $settings.localResolution) {
                    ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
                }
                bitrateRow(title: "Bitrate (home)", value: $settings.localBitrate)
                Picker("Resolution (internet)", selection: $settings.remoteResolution) {
                    ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
                }
                bitrateRow(title: "Bitrate (internet)", value: $settings.remoteBitrate)
                Toggle("60 fps", isOn: $settings.fps60)
                Picker("Codec", selection: $settings.codec) {
                    ForEach(StreamCodec.allCases) { Text($0.label).tag($0) }
                }
                Button("Use best quality for this network") {
                    settings.localResolution = .p1080
                    settings.localBitrate = 40_000
                    settings.remoteResolution = .p1080
                    settings.remoteBitrate = 15_000
                    settings.fps60 = true
                    settings.codec = .auto
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Automatic picks HEVC HDR on PS5 when your display supports HDR (HEVC otherwise) and H.264 on PS4. For HDR also enable HDR on the console (Settings › Screen and Video › Video Output › HDR). PlayStation Remote Play streams up to 1080p60 on every console, PS5 Pro included.")
            }

            Section {
                Picker("Video scaling", selection: $settings.videoFill) {
                    ForEach(VideoFill.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Ambient fill for letterbox", isOn: $settings.ambientFill)
                Toggle("Split stream at the fold", isOn: $settings.foldedSplit)
                Toggle("Stream to external display", isOn: $settings.useExternalDisplay)
                if display.hasExternalDisplay {
                    LabeledContent("External display", value: "\(Int(display.externalSize.width))×\(Int(display.externalSize.height))")
                }
            } header: {
                Text("Display & iPhone Duo")
            } footer: {
                Text("When iPhone Duo is partially folded, the stream plays on one half and the other half becomes a touchpad and control deck. Ambient fill extends the picture into the bars on the near-square inner display. With an external display connected, video plays there in full quality (HDR when supported) and your iPhone becomes the touchpad.")
            }

            Section {
                Stepper(value: $settings.audioBufferMs, in: 20...150, step: 10) {
                    LabeledContent("Audio buffer", value: "\(settings.audioBufferMs) ms")
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Lower is tighter A/V sync; raise it if audio crackles on a busy network. Audio that falls behind is dropped automatically so it never drifts out of sync with the picture.")
            }

            Section("Controllers") {
                NavigationLink { ControllersView() } label: { Label("Controllers & couch co-op", systemImage: "gamecontroller") }
                Toggle("Touch controls when no controller", isOn: $settings.touchControls)
                if settings.touchControls {
                    Slider(value: $settings.touchControlsOpacity, in: 0.2...1) { Text("Opacity") }
                }
            }

            Section {
                ForEach(store.manualHosts, id: \.self) { h in
                    Text(h)
                }
                .onDelete { idx in
                    let hosts = idx.map { store.manualHosts[$0] }
                    for h in hosts { store.removeManualHost(h) }
                }
                Toggle("Put console to sleep on disconnect", isOn: $settings.sleepOnDisconnect)
                Stepper(value: $settings.packetLossMax, in: 0.01...0.2, step: 0.01) {
                    LabeledContent("Packet loss tolerance", value: "\(Int(settings.packetLossMax * 100))%")
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Manually added addresses are also scanned. Higher packet-loss tolerance keeps the bitrate up on lossy Wi-Fi at the cost of more artifacts.")
            }

            Section {
                Toggle("Show statistics overlay", isOn: $settings.showStats)
                Toggle("Verbose logging", isOn: $settings.verboseLogging)
                if psn.isSignedIn {
                    Button {
                        Task {
                            if PSNDiagnostics.backoffRemaining > 0 {
                                ShiroLog.shared.info("PSN diagnostics skipped: still in Sony's back-off for \(Int(PSNDiagnostics.backoffRemaining)) s")
                            } else if let token = try? await psn.validAccessToken() {
                                let r = await PSNDiagnostics.run(token: token)
                                if r.status == 403 { PSNDiagnostics.startBackoff(seconds: max(r.retryMinSeconds ?? 120, 120)) }
                            }
                        }
                    } label: {
                        Label("Test PSN Remote Play connection", systemImage: "stethoscope")
                    }
                }
                NavigationLink {
                    LogReviewView(names: knownNames)
                } label: {
                    Label("Review & share log", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Logs stay on this iPhone unless you share them. Before sharing, console names, IP and MAC addresses, console IDs, e-mail addresses and anything token-like are replaced with placeholders — you can read exactly what will be sent first.")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
                Link(destination: URL(string: "https://github.com/westernpluto/Shiro")!) {
                    Label("Source code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/chiaki-ng/chiaki-ng")!) {
                    Label("Powered by chiaki-ng", systemImage: "heart")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Shiro is not affiliated with or endorsed by Sony Interactive Entertainment. PlayStation, PS4, PS5 and DualSense are trademarks of Sony Interactive Entertainment Inc.")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showLogin) { PSNLoginView() }
    }

    private var knownNames: [String] {
        store.registered.map(\.nickname)
            + store.discovered.values.map(\.name)
            + store.psnDevices.map(\.name)
    }

    private func bitrateRow(title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: "%.1f Mbps", Double(value.wrappedValue) / 1000))
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0 / 500) * 500 }),
                   in: 2_000...50_000)
        }
    }
}

struct ControllersView: View {
    @EnvironmentObject private var input: InputManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if input.controllers.isEmpty {
                    Label("No controllers connected", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
                ForEach(input.controllers) { c in
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                        VStack(alignment: .leading) {
                            Text("Player \(c.player) · \(c.name)")
                            Text(c.kind).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let b = c.battery {
                            Text("\(Int(b * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connected")
            } footer: {
                Text("Pair a DualSense, DualSense Edge, DualShock 4, Xbox or MFi controller in iOS Settings › Bluetooth. Controllers connected over USB-C work too.")
            }

            Section {
                Picker("Mode", selection: $settings.coopMode) {
                    ForEach(CoopMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Couch co-op")
            } footer: {
                Text("PlayStation Remote Play carries one controller's input to the console. Shared mode merges every controller (great for helping a friend or games with shared control). Hand-off gives control to whoever pressed a button last. For split-screen games with separate players, connect the extra controllers directly to the console — they play alongside the streamed controller.")
            }

            Section("Features") {
                Toggle("DualSense features (adaptive triggers, haptics)", isOn: $settings.dualSenseFeatures)
                Toggle("Motion controls", isOn: $settings.motionControls)
                Toggle("Swap ✕ and ◯", isOn: $settings.swapCrossCircle)
                Slider(value: $settings.rumbleIntensity, in: 0...1) { Text("Rumble") } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
        }
        .navigationTitle("Controllers")
    }
}

extension Bundle {
    var versionString: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// Shows the redacted log so the user can check what they're sharing.
struct LogReviewView: View {
    let names: [String]
    @State private var text = ""
    @State private var fileURL: URL?

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "The log is empty." : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Log (redacted)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = fileURL {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .onAppear {
            text = ShiroLog.redact(ShiroLog.shared.snapshot(), names: names)
            fileURL = ShiroLog.shared.export(redactingNames: names)
        }
    }
}
