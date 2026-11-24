import SwiftUI
import AVFoundation

/// UIKit view hosting the hardware video layer, plus an optional blurred
/// "ambient" copy of the picture that fills letterbox bars. iPhone Duo's inner
/// display is close to square, so a 16:9 stream would otherwise sit between
/// large black bars; the HIG asks games to fill that padding with artwork.
final class StreamVideoView: UIView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let ambientLayer = AVSampleBufferDisplayLayer()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let dim = UIView()

    weak var renderer: VideoRenderer? {
        didSet {
            guard renderer !== oldValue else { return }
            oldValue?.detach(videoLayer)
            oldValue?.detach(ambientLayer)
            reattach()
        }
    }

    var fill: VideoFill = .fit { didSet { setNeedsLayout() } }
    var ambient = true { didSet { setNeedsLayout() } }
    private var ambientAttached = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        ambientLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(ambientLayer)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        addSubview(blur)
        addSubview(dim)
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reattach()
    }

    private func reattach() {
        guard let r = renderer else { return }
        if window != nil {
            r.attach(videoLayer)
            updateAmbient()
        } else {
            r.detach(videoLayer)
            r.detach(ambientLayer)
            ambientAttached = false
        }
    }

    /// Whether the letterbox area is large enough to be worth filling.
    private var hasLetterbox: Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let viewAspect = bounds.width / bounds.height
        let videoAspect: CGFloat = 16.0 / 9.0
        return abs(viewAspect - videoAspect) / videoAspect > 0.08
    }

    private func updateAmbient() {
        let want = ambient && fill == .fit && hasLetterbox && window != nil
        blur.isHidden = !want
        dim.isHidden = !want
        ambientLayer.isHidden = !want
        guard let r = renderer, want != ambientAttached else { return }
        ambientAttached = want
        if want { r.attach(ambientLayer) } else { r.detach(ambientLayer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch fill {
        case .fit: videoLayer.videoGravity = .resizeAspect
        case .fill: videoLayer.videoGravity = .resizeAspectFill
        case .stretch: videoLayer.videoGravity = .resize
        }
        videoLayer.frame = bounds
        ambientLayer.frame = bounds.insetBy(dx: -40, dy: -40)
        blur.frame = bounds
        dim.frame = bounds
        CATransaction.commit()
        updateAmbient()
    }
}

struct VideoSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    var fill: VideoFill
    var ambient: Bool

    func makeUIView(context: Context) -> StreamVideoView {
        let v = StreamVideoView()
        v.fill = fill
        v.ambient = ambient
        v.renderer = renderer
        return v
    }

    func updateUIView(_ v: StreamVideoView, context: Context) {
        v.fill = fill
        v.ambient = ambient
        v.renderer = renderer
    }

    static func dismantleUIView(_ v: StreamVideoView, coordinator: ()) {
        v.renderer = nil
    }
}
