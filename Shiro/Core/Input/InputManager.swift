import Foundation
import CoreGraphics
import GameController
import CoreHaptics
import Combine

struct ControllerInfo: Identifiable, Equatable {
    var id: ObjectIdentifier
    var name: String
    var kind: String
    var player: Int
    var battery: Float?
    var isActive: Bool
}

/// Collects input from every connected controller (DualSense, DualShock 4,
/// Xbox, MFi, Switch Pro…) plus the on-screen controls, combines them according
/// to the couch co-op mode, and routes console feedback (rumble, adaptive
/// triggers, light bar) back to the hardware.
final class InputManager: ObservableObject {
    static let shared = InputManager()

    @Published private(set) var controllers: [ControllerInfo] = []

    private final class Pad {
        let controller: GCController
        var state = ChiakiControllerState()
        var orientation = UnsafeMutablePointer<ChiakiOrientationTracker>.allocate(capacity: 1)
        var touchIds: [Int8] = [-1, -1]
        var lastActive = Date.distantPast
        var motors: [RumbleMotor] = []
        var lastMotionTime: TimeInterval = 0

        init(_ c: GCController) {
            controller = c
            chiaki_controller_state_set_idle(&state)
            chiaki_orientation_tracker_init(orientation)
        }
        deinit {
            orientation.deallocate()
        }
    }

    private var pads: [ObjectIdentifier: Pad] = [:]
    private var order: [ObjectIdentifier] = []
    private weak var session: StreamSession?
    private var isPS5 = true
    private let settings = AppSettings.shared

    /// On-screen gamepad state (set by TouchGamepadView).
    private var virtualState = ChiakiControllerState()
    /// On-screen touchpad state (set by TouchpadView).
    private var touchpadState = ChiakiControllerState()

    // Feedback (written from chiaki threads, applied on hapticsQueue).
    private let hapticsQueue = DispatchQueue(label: "shiro.haptics", qos: .userInteractive)
    private var rumbleLeft: Float = 0, rumbleRight: Float = 0
    private var envLeft: Float = 0, envRight: Float = 0
    private var hapticScale: Float = 1
    private var triggerScale: Float = 1
    private var deviceMotor: RumbleMotor?
    // Snapshots owned by hapticsQueue (pads/order are mutated on the main thread).
    private var hPads: [ObjectIdentifier: Pad] = [:]
    private var hActive: ObjectIdentifier?

    private init() {
        chiaki_controller_state_set_idle(&virtualState)
        chiaki_controller_state_set_idle(&touchpadState)
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let c = n.object as? GCController else { return }
            self?.add(c)
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let c = n.object as? GCController else { return }
            self?.remove(c)
        }
        for c in GCController.controllers() { add(c) }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    // MARK: Session

    func attach(_ session: StreamSession) {
        self.session = session
        isPS5 = session.isPS5
        hapticsQueue.async { [weak self] in
            guard let self = self else { return }
            if self.deviceMotor == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                self.deviceMotor = RumbleMotor(engine: try? CHHapticEngine())
            }
        }
        for pad in pads.values { setupFeedback(pad) }
        send()
    }

    func detach(_ session: StreamSession) {
        guard self.session === session else { return }
        self.session = nil
        hapticsQueue.async { [weak self] in
            guard let self = self else { return }
            self.rumbleLeft = 0; self.rumbleRight = 0; self.envLeft = 0; self.envRight = 0
            for pad in self.hPads.values { pad.motors.forEach { $0.stop() }; pad.motors = [] }
            self.deviceMotor?.stop()
            self.deviceMotor = nil
        }
        DispatchQueue.main.async {
            for pad in self.pads.values {
                if let ds = pad.controller.physicalInputProfile as? GCDualSenseGamepad {
                    ds.leftTrigger.setModeOff()
                    ds.rightTrigger.setModeOff()
                }
            }
        }
    }

    // MARK: Controllers

    private func add(_ c: GCController) {
        let id = ObjectIdentifier(c)
        guard pads[id] == nil else { return }
        let pad = Pad(c)
        pads[id] = pad
        order.append(id)
        c.playerIndex = GCControllerPlayerIndex(rawValue: min(order.count - 1, 3)) ?? .indexUnset

        if let gp = c.extendedGamepad {
            gp.buttonHome?.preferredSystemGestureState = .disabled
            gp.buttonOptions?.preferredSystemGestureState = .disabled
            gp.buttonMenu.preferredSystemGestureState = .disabled
            gp.valueChangedHandler = { [weak self, weak pad] gamepad, _ in
                guard let self = self, let pad = pad else { return }
                self.update(pad, from: gamepad)
            }
        } else if let micro = c.microGamepad {
            micro.reportsAbsoluteDpadValues = true
            micro.valueChangedHandler = { [weak self, weak pad] gamepad, _ in
                guard let self = self, let pad = pad else { return }
                self.update(pad, micro: gamepad)
            }
        }
        if let motion = c.motion {
            if motion.sensorsRequireManualActivation { motion.sensorsActive = settings.motionControls }
            motion.valueChangedHandler = { [weak self, weak pad] m in
                guard let self = self, let pad = pad else { return }
                self.updateMotion(pad, m)
            }
        }
        if session != nil { setupFeedback(pad) }
        publish()
        ShiroLog.shared.info("Controller connected: \(c.vendorName ?? "Controller") (\(c.productCategory))")
    }

    private func remove(_ c: GCController) {
        let id = ObjectIdentifier(c)
        if let pad = pads[id] {
            hapticsQueue.async { pad.motors.forEach { $0.stop() } }
        }
        pads.removeValue(forKey: id)
        order.removeAll { $0 == id }
        for (i, oid) in order.enumerated() {
            pads[oid]?.controller.playerIndex = GCControllerPlayerIndex(rawValue: min(i, 3)) ?? .indexUnset
        }
        publish()
        send()
    }

    private func publish() {
        let active = activePadId()
        let snapshot = pads
        hapticsQueue.async { self.hPads = snapshot; self.hActive = active }
        controllers = order.compactMap { id in
            guard let p = pads[id] else { return nil }
            let c = p.controller
            return ControllerInfo(id: id, name: c.vendorName ?? "Controller", kind: c.productCategory,
                                  player: (order.firstIndex(of: id) ?? 0) + 1,
                                  battery: c.battery.map { $0.batteryLevel },
                                  isActive: settings.coopMode == .merge || active == id)
        }
    }

    // MARK: Input mapping

    private func update(_ pad: Pad, from gp: GCExtendedGamepad) {
        var s = pad.state
        var b: UInt32 = 0
        func set(_ pressed: Bool, _ button: ChiakiControllerButton) {
            if pressed { b |= button.rawValue }
        }
        let swap = settings.swapCrossCircle
        set(gp.buttonA.isPressed, swap ? CHIAKI_CONTROLLER_BUTTON_MOON : CHIAKI_CONTROLLER_BUTTON_CROSS)
        set(gp.buttonB.isPressed, swap ? CHIAKI_CONTROLLER_BUTTON_CROSS : CHIAKI_CONTROLLER_BUTTON_MOON)
        set(gp.buttonX.isPressed, CHIAKI_CONTROLLER_BUTTON_BOX)
        set(gp.buttonY.isPressed, CHIAKI_CONTROLLER_BUTTON_PYRAMID)
        set(gp.dpad.left.isPressed, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT)
        set(gp.dpad.right.isPressed, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT)
        set(gp.dpad.up.isPressed, CHIAKI_CONTROLLER_BUTTON_DPAD_UP)
        set(gp.dpad.down.isPressed, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN)
        set(gp.leftShoulder.isPressed, CHIAKI_CONTROLLER_BUTTON_L1)
        set(gp.rightShoulder.isPressed, CHIAKI_CONTROLLER_BUTTON_R1)
        set(gp.leftThumbstickButton?.isPressed ?? false, CHIAKI_CONTROLLER_BUTTON_L3)
        set(gp.rightThumbstickButton?.isPressed ?? false, CHIAKI_CONTROLLER_BUTTON_R3)
        set(gp.buttonMenu.isPressed, CHIAKI_CONTROLLER_BUTTON_OPTIONS)
        set(gp.buttonOptions?.isPressed ?? false, CHIAKI_CONTROLLER_BUTTON_SHARE)
        set(gp.buttonHome?.isPressed ?? false, CHIAKI_CONTROLLER_BUTTON_PS)

        if let ds = gp as? GCDualSenseGamepad {
            set(ds.touchpadButton.isPressed, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
            updateTouch(&s, pad: pad, slot: 0, x: ds.touchpadPrimary.xAxis.value, y: ds.touchpadPrimary.yAxis.value)
            updateTouch(&s, pad: pad, slot: 1, x: ds.touchpadSecondary.xAxis.value, y: ds.touchpadSecondary.yAxis.value)
        } else if let ds4 = gp as? GCDualShockGamepad {
            set(ds4.touchpadButton.isPressed, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
            updateTouch(&s, pad: pad, slot: 0, x: ds4.touchpadPrimary.xAxis.value, y: ds4.touchpadPrimary.yAxis.value)
            updateTouch(&s, pad: pad, slot: 1, x: ds4.touchpadSecondary.xAxis.value, y: ds4.touchpadSecondary.yAxis.value)
        }

        s.buttons = b
        s.l2_state = UInt8(max(0, min(255, gp.leftTrigger.value * 255)))
        s.r2_state = UInt8(max(0, min(255, gp.rightTrigger.value * 255)))
        s.left_x = Self.axis(gp.leftThumbstick.xAxis.value)
        s.left_y = Self.axis(-gp.leftThumbstick.yAxis.value)
        s.right_x = Self.axis(gp.rightThumbstick.xAxis.value)
        s.right_y = Self.axis(-gp.rightThumbstick.yAxis.value)

        if b != 0 || s.l2_state > 20 || s.r2_state > 20 || abs(Int(s.left_x)) > 8000 || abs(Int(s.right_x)) > 8000 {
            pad.lastActive = Date()
        }
        pad.state = s
        send()
    }

    private func update(_ pad: Pad, micro gp: GCMicroGamepad) {
        var s = pad.state
        var b: UInt32 = 0
        if gp.buttonA.isPressed { b |= CHIAKI_CONTROLLER_BUTTON_CROSS.rawValue }
        if gp.buttonX.isPressed { b |= CHIAKI_CONTROLLER_BUTTON_MOON.rawValue }
        if gp.buttonMenu.isPressed { b |= CHIAKI_CONTROLLER_BUTTON_OPTIONS.rawValue }
        s.buttons = b
        s.left_x = Self.axis(gp.dpad.xAxis.value)
        s.left_y = Self.axis(-gp.dpad.yAxis.value)
        if b != 0 { pad.lastActive = Date() }
        pad.state = s
        send()
    }

    private var touchMax: (x: Float, y: Float) { isPS5 ? (1919, 1079) : (1919, 941) }

    private func updateTouch(_ s: inout ChiakiControllerState, pad: Pad, slot: Int, x: Float, y: Float) {
        let touching = !(x == 0 && y == 0)
        let tx = UInt16(max(0, min(touchMax.x, (x + 1) / 2 * touchMax.x)))
        let ty = UInt16(max(0, min(touchMax.y, (1 - (y + 1) / 2) * touchMax.y)))
        let id = pad.touchIds[slot]
        if touching {
            if id < 0 {
                pad.touchIds[slot] = chiaki_controller_state_start_touch(&s, tx, ty)
            } else {
                chiaki_controller_state_set_touch_pos(&s, UInt8(id), tx, ty)
            }
        } else if id >= 0 {
            chiaki_controller_state_stop_touch(&s, UInt8(id))
            pad.touchIds[slot] = -1
        }
    }

    private func updateMotion(_ pad: Pad, _ m: GCMotion) {
        guard settings.motionControls else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let ax: Double, ay: Double, az: Double
        if m.hasGravityAndUserAcceleration {
            ax = m.gravity.x + m.userAcceleration.x
            ay = m.gravity.y + m.userAcceleration.y
            az = m.gravity.z + m.userAcceleration.z
        } else {
            ax = m.acceleration.x; ay = m.acceleration.y; az = m.acceleration.z
        }
        let r = m.rotationRate
        let ts = UInt32(truncatingIfNeeded: UInt64(now * 1_000_000))
        chiaki_orientation_tracker_update(pad.orientation, Float(r.x), Float(r.y), Float(r.z),
                                          Float(ax), Float(ay), Float(az), nil, false, ts)
        var s = pad.state
        chiaki_orientation_tracker_apply_to_controller_state(pad.orientation, &s)
        pad.state = s
        // Motion arrives at a high rate; cap transmission to ~250 Hz.
        if now - pad.lastMotionTime > 0.004 {
            pad.lastMotionTime = now
            send()
        }
    }

    func resetMotion() {
        DispatchQueue.main.async {
            for pad in self.pads.values { chiaki_orientation_tracker_init(pad.orientation) }
        }
    }

    static func axis(_ v: Float) -> Int16 {
        Int16(max(-32767, min(32767, v * 32767)))
    }

    // MARK: On-screen controls

    func setVirtual(buttons: UInt32, l2: UInt8, r2: UInt8, left: CGPoint, right: CGPoint) {
        virtualState.buttons = buttons
        virtualState.l2_state = l2
        virtualState.r2_state = r2
        virtualState.left_x = Self.axis(Float(left.x))
        virtualState.left_y = Self.axis(Float(left.y))
        virtualState.right_x = Self.axis(Float(right.x))
        virtualState.right_y = Self.axis(Float(right.y))
        send()
    }

    /// Normalised (0…1) touch positions from the on-screen touchpad. Key = finger id.
    private var screenTouchIds: [Int: Int8] = [:]

    func screenTouch(id: Int, location: CGPoint?) {
        if let p = location {
            let x = UInt16(max(0, min(touchMax.x, Float(p.x) * touchMax.x)))
            let y = UInt16(max(0, min(touchMax.y, Float(p.y) * touchMax.y)))
            if let tid = screenTouchIds[id], tid >= 0 {
                chiaki_controller_state_set_touch_pos(&touchpadState, UInt8(tid), x, y)
            } else {
                screenTouchIds[id] = chiaki_controller_state_start_touch(&touchpadState, x, y)
            }
        } else if let tid = screenTouchIds.removeValue(forKey: id), tid >= 0 {
            chiaki_controller_state_stop_touch(&touchpadState, UInt8(tid))
        }
        send()
    }

    func setTouchpadButton(_ pressed: Bool) {
        if pressed {
            touchpadState.buttons |= CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue
        } else {
            touchpadState.buttons &= ~CHIAKI_CONTROLLER_BUTTON_TOUCHPAD.rawValue
        }
        send()
    }

    /// Presses a button briefly (PS, Options, Share… from the stream menu).
    func tap(_ button: ChiakiControllerButton) {
        touchpadState.buttons |= button.rawValue
        send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.touchpadState.buttons &= ~button.rawValue
            self.send()
        }
    }

    // MARK: Combining

    private func activePadId() -> ObjectIdentifier? {
        switch settings.coopMode {
        case .merge: return nil
        case .single: return order.first
        case .handoff: return order.max { (pads[$0]?.lastActive ?? .distantPast) < (pads[$1]?.lastActive ?? .distantPast) }
        }
    }

    private var lastActiveId: ObjectIdentifier?

    private func send() {
        var out = ChiakiControllerState()
        chiaki_controller_state_set_idle(&out)
        func or(_ other: ChiakiControllerState) {
            var a = out
            var b = other
            chiaki_controller_state_or(&out, &a, &b)
        }
        if let active = activePadId() {
            if let p = pads[active] { or(p.state) }
            if active != lastActiveId {
                lastActiveId = active
                DispatchQueue.main.async { self.publish() }
            }
        } else {
            for id in order { if let p = pads[id] { or(p.state) } }
        }
        or(virtualState)
        or(touchpadState)
        session?.setControllerState(&out)
    }

    // MARK: Feedback from the console

    private func setupFeedback(_ pad: Pad) {
        let c = pad.controller
        hapticsQueue.async {
            guard pad.motors.isEmpty else { return }
            var motors: [RumbleMotor] = []
            if let l = RumbleMotor(controller: c, locality: .leftHandle),
               let r = RumbleMotor(controller: c, locality: .rightHandle) {
                motors = [l, r]
            } else if let all = RumbleMotor(controller: c, locality: .default) {
                motors = [all]
            }
            pad.motors = motors
        }
    }

    /// Classic rumble (PS4 games, or PS5 with DualSense features off).
    func rumble(left: UInt8, right: UInt8) {
        hapticsQueue.async {
            self.rumbleLeft = Float(left) / 255
            self.rumbleRight = Float(right) / 255
            self.applyRumble()
        }
    }

    /// DualSense haptic audio envelope, converted to rumble.
    func hapticsEnvelope(left: Float, right: Float) {
        hapticsQueue.async {
            // Smooth the decay so short haptic transients are still felt.
            self.envLeft = max(left, self.envLeft * 0.6)
            self.envRight = max(right, self.envRight * 0.6)
            self.applyRumble()
        }
    }

    private func applyRumble() {
        let scale = Float(settings.rumbleIntensity) * hapticScale
        let l = min(1, max(rumbleLeft, envLeft * 1.6)) * scale
        let r = min(1, max(rumbleRight, envRight * 1.6)) * scale
        let active = hActive
        var any = false
        for (id, pad) in hPads where active == nil || active == id {
            any = any || !pad.motors.isEmpty
            if pad.motors.count == 2 {
                pad.motors[0].set(l)
                pad.motors[1].set(r)
            } else {
                pad.motors.first?.set(max(l, r))
            }
        }
        // No controller: rumble the phone itself while using touch controls.
        if !any { deviceMotor?.set(max(l, r) * 0.7) }
    }

    func setHapticIntensity(level: UInt8) {
        // ChiakiDualSenseEffectIntensity: 0 off … 3 weak (console setting)
        let s: Float = [0: 0, 1: 1, 2: 0.66, 3: 0.33][Int(level)] ?? 1
        hapticsQueue.async { self.hapticScale = s }
    }

    func setTriggerIntensity(level: UInt8) {
        let s: Float = [0: 0, 1: 1, 2: 0.66, 3: 0.33][Int(level)] ?? 1
        DispatchQueue.main.async { self.triggerScale = s }
    }

    func setTriggerEffects(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
        DispatchQueue.main.async {
            guard self.settings.dualSenseFeatures else { return }
            for pad in self.pads.values {
                guard let ds = pad.controller.physicalInputProfile as? GCDualSenseGamepad else { continue }
                TriggerEffect.apply(type: typeLeft, data: left, to: ds.leftTrigger, scale: self.triggerScale)
                TriggerEffect.apply(type: typeRight, data: right, to: ds.rightTrigger, scale: self.triggerScale)
            }
        }
    }

    func setLight(r: UInt8, g: UInt8, b: UInt8) {
        for pad in pads.values {
            pad.controller.light?.color = GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255)
        }
    }

    func setConsolePlayerIndex(_ index: Int) {
        // The console reports which player slot this stream occupies; reflect it on player 1.
        guard let first = order.first, let pad = pads[first] else { return }
        pad.controller.playerIndex = GCControllerPlayerIndex(rawValue: max(0, min(3, index - 1))) ?? .index1
    }
}
