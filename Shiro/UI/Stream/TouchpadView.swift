import SwiftUI
import UIKit

/// Multi-touch surface that behaves like the DualSense touchpad: finger
/// positions are forwarded continuously, a quick tap clicks the pad.
final class TouchpadUIView: UIView {
    private var starts: [ObjectIdentifier: (point: CGPoint, time: TimeInterval)] = [:]
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextId = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(1, p.x / max(bounds.width, 1))), y: max(0, min(1, p.y / max(bounds.height, 1))))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let key = ObjectIdentifier(t)
            let id = nextId; nextId += 1
            ids[key] = id
            let p = t.location(in: self)
            starts[key] = (p, t.timestamp)
            InputManager.shared.screenTouch(id: id, location: normalized(p))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let id = ids[ObjectIdentifier(t)] else { continue }
            InputManager.shared.screenTouch(id: id, location: normalized(t.location(in: self)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let id = ids.removeValue(forKey: key) else { continue }
            InputManager.shared.screenTouch(id: id, location: nil)
            if !cancelled, let s = starts[key] {
                let p = t.location(in: self)
                let moved = hypot(p.x - s.point.x, p.y - s.point.y)
                if t.timestamp - s.time < 0.22 && moved < 12 {
                    InputManager.shared.tap(CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            starts.removeValue(forKey: key)
        }
    }
}

struct TouchpadView: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchpadUIView { TouchpadUIView() }
    func updateUIView(_ uiView: TouchpadUIView, context: Context) {}
}
