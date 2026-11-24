import CoreHaptics
import GameController

/// A continuously playing haptic "motor" whose strength can be changed with
/// very low latency (dynamic intensity parameter instead of new patterns).
final class RumbleMotor {
    private let engine: CHHapticEngine
    private var player: CHHapticAdvancedPatternPlayer?
    private var current: Float = 0

    init?(engine: CHHapticEngine?) {
        guard let engine = engine else { return nil }
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        engine.resetHandler = { [weak self] in
            self?.player = nil
            try? self?.engine.start()
        }
        engine.stoppedHandler = { [weak self] _ in self?.player = nil }
        do { try engine.start() } catch { return nil }
    }

    convenience init?(controller: GCController, locality: GCHapticsLocality) {
        self.init(engine: controller.haptics?.createEngine(withLocality: locality))
    }

    func set(_ intensity: Float) {
        let v = max(0, min(1, intensity))
        if abs(v - current) < 0.02 && !(v == 0 && current != 0) { return }
        current = v
        do {
            if v < 0.02 {
                try player?.stop(atTime: CHHapticTimeImmediate)
                player = nil
                return
            }
            if player == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                ], relativeTime: 0, duration: 30)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let p = try engine.makeAdvancedPlayer(with: pattern)
                p.loopEnabled = true
                try p.start(atTime: CHHapticTimeImmediate)
                player = p
            }
            try player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)],
                                       atTime: CHHapticTimeImmediate)
        } catch {
            player = nil
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        current = 0
        engine.stop(completionHandler: nil)
    }
}

/// Translates PlayStation adaptive-trigger effect packets into
/// GCDualSenseAdaptiveTrigger modes.
enum TriggerEffect {
    static func apply(type: UInt8, data: [UInt8], to trigger: GCDualSenseAdaptiveTrigger, scale: Float) {
        func zones(_ lo: UInt8, _ hi: UInt8) -> [Int] {
            let mask = UInt16(lo) | UInt16(hi) << 8
            return (0..<10).filter { mask & (1 << $0) != 0 }
        }
        func strength3(_ zoneIndex: Int, _ bytes: ArraySlice<UInt8>) -> Float {
            // 10 zones × 3 bits packed little-endian starting at bytes.startIndex
            var packed: UInt64 = 0
            for (i, b) in bytes.prefix(4).enumerated() { packed |= UInt64(b) << (8 * UInt64(i)) }
            let v = (packed >> UInt64(zoneIndex * 3)) & 0x7
            return Float(v + 1) / 8
        }
        let d = data + [UInt8](repeating: 0, count: max(0, 10 - data.count))
        switch type {
        case 0x21: // feedback (per-zone resistance)
            let z = zones(d[0], d[1])
            guard let first = z.first else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(Float(first) / 9, resistiveStrength: strength3(first, d[2..<6]) * scale)
        case 0x25: // weapon (start/end click)
            let z = zones(d[0], d[1])
            guard let start = z.first, let end = z.last, end > start else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(Float(start) / 9, endPosition: Float(end) / 9,
                                                   resistiveStrength: Float((d[2] & 0x7) + 1) / 8 * scale)
        case 0x26: // vibration
            let z = zones(d[0], d[1])
            guard let first = z.first else { trigger.setModeOff(); return }
            trigger.setModeVibrationWithStartPosition(Float(first) / 9,
                                                      amplitude: strength3(first, d[2..<6]) * scale,
                                                      frequency: Float(d[8]) / 255)
        case 0x01: // legacy: simple resistance
            trigger.setModeFeedbackWithStartPosition(Float(d[0]) / 255, resistiveStrength: Float(d[1]) / 255 * scale)
        case 0x02: // legacy: simple weapon
            guard d[1] > d[0] else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(Float(d[0]) / 255, endPosition: Float(d[1]) / 255,
                                                   resistiveStrength: Float(d[2]) / 255 * scale)
        case 0x06: // legacy: vibration
            trigger.setModeVibrationWithStartPosition(Float(d[2]) / 255, amplitude: Float(d[1]) / 255 * scale,
                                                      frequency: Float(d[0]) / 255)
        default:
            trigger.setModeOff()
        }
    }
}
