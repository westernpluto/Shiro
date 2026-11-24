import SwiftUI

/// The "second screen" shown below / beside the fold on iPhone Duo, or on the
/// whole phone while the video plays on an external display. It turns the
/// phone into a DualSense touchpad plus quick system controls.
struct CompanionPanel: View {
    @ObservedObject var session: StreamSession
    @EnvironmentObject private var input: InputManager
    @EnvironmentObject private var settings: AppSettings
    var showsGamepad: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                header
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1))
                    VStack(spacing: 6) {
                        Image(systemName: "hand.point.up.left")
                            .font(.title2)
                        Text("Touchpad")
                            .font(.footnote.weight(.semibold))
                        Text("Tap to click · drag to swipe")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)
                    TouchpadView()
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    if showsGamepad {
                        TouchGamepad(opacity: settings.touchControlsOpacity, compact: true)
                    }
                }
                systemButtons
            }
            .padding()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isPS5 ? "playstation.logo" : "gamecontroller.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.serverNickname ?? session.request.nickname)
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            ForEach(input.controllers) { c in
                Label("P\(c.player)", systemImage: "gamecontroller.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(c.isActive ? Color.accentColor : .secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(c.player)").font(.system(size: 9, weight: .bold)).offset(x: 4, y: 4)
                    }
            }
        }
        .foregroundStyle(.white)
    }

    private var statusLine: String {
        let s = session.stats
        guard s.width > 0 else { return "Connecting…" }
        return "\(s.height)p · \(Int(s.fps.rounded())) fps · \(String(format: "%.1f", s.measuredMbps)) Mbps\(s.hdr ? " · HDR" : "")"
    }

    private var systemButtons: some View {
        HStack(spacing: 10) {
            CompanionButton(title: "Create", symbol: "square.and.arrow.up") { input.tap(CHIAKI_CONTROLLER_BUTTON_SHARE) }
            CompanionButton(title: "Home", symbol: "house.fill") { input.tap(CHIAKI_CONTROLLER_BUTTON_PS) }
            CompanionButton(title: "Options", symbol: "line.3.horizontal") { input.tap(CHIAKI_CONTROLLER_BUTTON_OPTIONS) }
            CompanionButton(title: session.micActive ? "Mic on" : "Mic off",
                            symbol: session.micActive ? "mic.fill" : "mic.slash.fill",
                            highlighted: session.micActive) { session.toggleMicrophone() }
        }
    }
}

struct CompanionButton: View {
    let title: String
    let symbol: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }
}
