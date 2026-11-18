import SwiftUI

/// A highlight sweeping across the content, for text that is still being worked on.
struct ShimmerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width * 1.5
                    LinearGradient(colors: [.clear, .white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .keyframeAnimator(initialValue: -1.0, repeating: true) { gradient, phase in
                            gradient.offset(x: phase * width)
                        } keyframes: { _ in
                            LinearKeyframe(1.0, duration: 1.5)
                        }
                }
            }
            .mask(content)
    }
}

extension View {
    @ViewBuilder
    func shimmer(active: Bool = true) -> some View {
        if active {
            modifier(ShimmerModifier())
        } else {
            self
        }
    }
}
