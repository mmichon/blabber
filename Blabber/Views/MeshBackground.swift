import SwiftUI

// Animated aurora-style background using shifting radial gradients
struct MeshBackground: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawMesh(ctx: ctx, size: size, t: t)
            }
        }
        .ignoresSafeArea()
    }

    private func drawMesh(ctx: GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height

        // Base fill
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.03, green: 0.03, blue: 0.13)))

        // Animated blobs
        let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, hue: CGFloat, speed: Double)] = [
            (0.25, 0.30, 0.55, 0.62, 0.21),   // indigo blob
            (0.75, 0.65, 0.50, 0.55, 0.17),   // blue blob
            (0.50, 0.80, 0.45, 0.70, 0.13),   // purple blob
            (0.80, 0.20, 0.40, 0.58, 0.19),   // cyan blob
            (0.15, 0.70, 0.38, 0.67, 0.23),   // violet blob
        ]

        for blob in blobs {
            let ox = sin(t * blob.speed) * w * 0.10
            let oy = cos(t * blob.speed * 1.3) * h * 0.08
            let cx = w * blob.x + ox
            let cy = h * blob.y + oy
            let radius = min(w, h) * blob.r

            let gradient = Gradient(stops: [
                .init(color: Color(hue: blob.hue, saturation: 0.85, brightness: 0.55, opacity: 0.38),
                      location: 0),
                .init(color: Color(hue: blob.hue, saturation: 0.85, brightness: 0.55, opacity: 0),
                      location: 1),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .radialGradient(gradient,
                                      center: CGPoint(x: cx, y: cy),
                                      startRadius: 0,
                                      endRadius: radius)
            )
        }

        // Subtle noise overlay: small dark vignette at corners
        let vignette = Gradient(stops: [
            .init(color: .black.opacity(0), location: 0.4),
            .init(color: .black.opacity(0.55), location: 1),
        ])
        let center = CGPoint(x: w/2, y: h/2)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(vignette, center: center,
                                       startRadius: min(w,h)*0.3,
                                       endRadius: max(w,h)*0.8))
    }
}

// Frosted glass card background
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}
