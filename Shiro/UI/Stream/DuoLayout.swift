import SwiftUI

/// iPhone Duo fold awareness.
///
/// iPhone Duo reports the hinge of a partially-open device as a `.division`
/// reserved region (iOS 27.1). When one is active we know the inner display is
/// split into two physical halves and arrange the stream around it.
enum FoldState: Equatable {
    case flat
    /// Partially folded. `axis` is the direction in which the two halves are laid out.
    case folded(axis: Axis, hinge: CGRect)
}

extension GeometryProxy {
    var foldState: FoldState {
        if #available(iOS 27.1, *) {
            let regions = reservedRegions(kind: .division)
            if let hinge = regions.first(where: { $0.isActive }) {
                let f = hinge.frame
                // A tall, narrow hinge splits the view left / right.
                return .folded(axis: f.height >= f.width ? .horizontal : .vertical, hinge: f)
            }
        }
        return .flat
    }

    /// Camera / sensor housings that occlude content (outer display camera,
    /// active inner camera). Used to keep interactive controls clear of them.
    var occludedRects: [CGRect] {
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .occlusion).filter { $0.isActive }.map { $0.frame }
        }
        return []
    }
}

/// Lays out a primary and secondary view around the fold when the device is
/// partially open (book or laptop pose), and shows only the primary view
/// otherwise. Uses the system `ArrangementView` on iOS 27.1+, which knows the
/// exact hinge geometry and reserved regions.
struct FoldArrangement<Primary: View, Secondary: View>: View {
    var splitWhenFolded: Bool
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        GeometryReader { proxy in
            let fold = proxy.foldState
            if splitWhenFolded, case .folded = fold {
                splitView(proxy: proxy, fold: fold)
            } else {
                primary()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func splitView(proxy: GeometryProxy, fold: FoldState) -> some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                PrimaryBox(content: primary())
            } secondary: {
                SecondaryBox(content: secondary())
            }
            .arrangementViewStyle(.split)
        } else {
            manualSplit(proxy: proxy, fold: fold)
        }
    }

    /// Fallback split for SDKs without ArrangementView: place the halves
    /// either side of the hinge rectangle.
    @ViewBuilder
    private func manualSplit(proxy: GeometryProxy, fold: FoldState) -> some View {
        if case .folded(let axis, let hinge) = fold {
            if axis == .horizontal {
                HStack(spacing: 0) {
                    primary().frame(width: max(0, hinge.minX))
                    Color.black.frame(width: hinge.width)
                    secondary().frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    primary().frame(height: max(0, hinge.minY))
                    Color.black.frame(height: hinge.height)
                    secondary().frame(maxHeight: .infinity)
                }
            }
        } else {
            primary()
        }
    }
}

private struct PrimaryBox<Content: View>: View {
    let content: Content
    var body: some View { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct SecondaryBox<Content: View>: View {
    let content: Content
    var body: some View { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
}
