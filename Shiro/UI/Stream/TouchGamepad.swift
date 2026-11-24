import SwiftUI

/// State of the on-screen controller, pushed to InputManager on every change.
final class VirtualPad: ObservableObject {
    private(set) var buttons: UInt32 = 0
    private(set) var left: CGPoint = .zero
    private(set) var right: CGPoint = .zero
    private var l2: UInt8 = 0
    private var r2: UInt8 = 0

    func set(_ button: ChiakiControllerButton, _ pressed: Bool) {
        if pressed { buttons |= button.rawValue } else { buttons &= ~button.rawValue }
        push()
    }

    func setTrigger(left isLeft: Bool, _ pressed: Bool) {
        if isLeft { l2 = pressed ? 255 : 0 } else { r2 = pressed ? 255 : 0 }
        push()
    }

    func setStick(left isLeft: Bool, _ v: CGPoint) {
        if isLeft { left = v } else { right = v }
        push()
    }

    func reset() {
        buttons = 0; left = .zero; right = .zero; l2 = 0; r2 = 0
        push()
    }

    private func push() {
        InputManager.shared.setVirtual(buttons: buttons, l2: l2, r2: r2, left: left, right: right)
    }
}

struct TouchGamepad: View {
    var opacity: Double
    var compact = false
    @StateObject private var pad = VirtualPad()

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let unit = max(36, min(64, size / (compact ? 6 : 7.5)))
            ZStack {
                // Shoulders
                VStack {
                    HStack {
                        VStack(spacing: 6) {
                            TriggerButton(label: "L2", pad: pad, isLeft: true, unit: unit)
                            PadButton(label: "L1", button: CHIAKI_CONTROLLER_BUTTON_L1, pad: pad, unit: unit, wide: true)
                        }
                        Spacer()
                        VStack(spacing: 6) {
                            TriggerButton(label: "R2", pad: pad, isLeft: false, unit: unit)
                            PadButton(label: "R1", button: CHIAKI_CONTROLLER_BUTTON_R1, pad: pad, unit: unit, wide: true)
                        }
                    }
                    Spacer()
                }

                // Left cluster
                HStack {
                    VStack(spacing: unit * 0.4) {
                        Spacer()
                        Stick(isLeft: true, pad: pad, unit: unit)
                        DPad(pad: pad, unit: unit)
                    }
                    Spacer()
                    // Right cluster
                    VStack(spacing: unit * 0.4) {
                        Spacer()
                        FaceButtons(pad: pad, unit: unit)
                        Stick(isLeft: false, pad: pad, unit: unit)
                    }
                }

                // System buttons
                VStack {
                    Spacer()
                    HStack(spacing: unit * 0.5) {
                        PadButton(symbol: "square.and.arrow.up", button: CHIAKI_CONTROLLER_BUTTON_SHARE, pad: pad, unit: unit * 0.75)
                        PadButton(symbol: "house.fill", button: CHIAKI_CONTROLLER_BUTTON_PS, pad: pad, unit: unit * 0.75)
                        PadButton(symbol: "line.3.horizontal", button: CHIAKI_CONTROLLER_BUTTON_OPTIONS, pad: pad, unit: unit * 0.75)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(12)
        }
        .opacity(opacity)
        .onDisappear { pad.reset() }
    }
}

private struct PadButton: View {
    var label: String? = nil
    var symbol: String? = nil
    let button: ChiakiControllerButton
    @ObservedObject var pad: VirtualPad
    var unit: CGFloat
    var wide = false
    @State private var pressed = false

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(pressed ? Color.white.opacity(0.55) : Color.black.opacity(0.35))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
            if let s = symbol {
                Image(systemName: s).font(.system(size: unit * 0.38, weight: .semibold))
            } else if let l = label {
                Text(l).font(.system(size: unit * 0.32, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: wide ? unit * 1.5 : unit, height: wide ? unit * 0.7 : unit)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !pressed {
                    pressed = true
                    pad.set(button, true)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
                }
            }
            .onEnded { _ in
                pressed = false
                pad.set(button, false)
            })
        .accessibilityLabel(label ?? symbol ?? "Button")
    }
}

private struct TriggerButton: View {
    let label: String
    @ObservedObject var pad: VirtualPad
    let isLeft: Bool
    var unit: CGFloat
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(pressed ? Color.white.opacity(0.55) : Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
            .overlay(Text(label).font(.system(size: unit * 0.3, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .frame(width: unit * 1.5, height: unit * 0.7)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; pad.setTrigger(left: isLeft, true) }
                }
                .onEnded { _ in pressed = false; pad.setTrigger(left: isLeft, false) })
    }
}

private struct FaceButtons: View {
    @ObservedObject var pad: VirtualPad
    var unit: CGFloat

    var body: some View {
        VStack(spacing: unit * 0.1) {
            PadButton(symbol: "triangle", button: CHIAKI_CONTROLLER_BUTTON_PYRAMID, pad: pad, unit: unit)
            HStack(spacing: unit * 0.9) {
                PadButton(symbol: "square", button: CHIAKI_CONTROLLER_BUTTON_BOX, pad: pad, unit: unit)
                PadButton(symbol: "circle", button: CHIAKI_CONTROLLER_BUTTON_MOON, pad: pad, unit: unit)
            }
            PadButton(symbol: "xmark", button: CHIAKI_CONTROLLER_BUTTON_CROSS, pad: pad, unit: unit)
        }
    }
}

private struct DPad: View {
    @ObservedObject var pad: VirtualPad
    var unit: CGFloat

    var body: some View {
        VStack(spacing: unit * 0.1) {
            PadButton(symbol: "arrowtriangle.up.fill", button: CHIAKI_CONTROLLER_BUTTON_DPAD_UP, pad: pad, unit: unit * 0.85)
            HStack(spacing: unit * 0.85) {
                PadButton(symbol: "arrowtriangle.left.fill", button: CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT, pad: pad, unit: unit * 0.85)
                PadButton(symbol: "arrowtriangle.right.fill", button: CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT, pad: pad, unit: unit * 0.85)
            }
            PadButton(symbol: "arrowtriangle.down.fill", button: CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN, pad: pad, unit: unit * 0.85)
        }
    }
}

private struct Stick: View {
    let isLeft: Bool
    @ObservedObject var pad: VirtualPad
    var unit: CGFloat
    @State private var offset: CGSize = .zero
    @State private var lastTap = Date.distantPast

    var body: some View {
        let radius = unit * 1.1
        ZStack {
            Circle().fill(Color.black.opacity(0.3))
                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                .frame(width: radius * 2, height: radius * 2)
            Circle().fill(Color.white.opacity(0.75))
                .frame(width: unit * 0.9, height: unit * 0.9)
                .offset(offset)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                var dx = v.translation.width, dy = v.translation.height
                let len = hypot(dx, dy)
                if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                offset = CGSize(width: dx, height: dy)
                pad.setStick(left: isLeft, CGPoint(x: dx / radius, y: dy / radius))
            }
            .onEnded { v in
                offset = .zero
                pad.setStick(left: isLeft, .zero)
                // Quick tap on the stick = L3 / R3 click.
                if hypot(v.translation.width, v.translation.height) < 6 {
                    let b = isLeft ? CHIAKI_CONTROLLER_BUTTON_L3 : CHIAKI_CONTROLLER_BUTTON_R3
                    InputManager.shared.tap(b)
                }
            })
    }
}
