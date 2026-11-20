import PeaCore
import SwiftUI

/// The dotted ring. Idle: still grey dots. Armed / choosing: the ring turns slowly with the artwork's
/// colours blended round it. Downloading: dots fill clockwise in the theme colour.
/// All motion is a rotation SwiftUI hands to the render server, so it stays fluid.
struct DotRing: View {
    let palette: [Color]
    let waving: Bool
    let working: Bool
    let progress: Double?
    /// First-run setup: how many steps are done out of how many.
    var steps: (done: Int, total: Int)?

    private static let grey = Color(white: 0.36)

    var body: some View {
        ZStack {
            if let steps {
                Dots(lineWidth: 2.6).foregroundStyle(Self.grey)
                let done = Double(steps.done) / Double(steps.total), next = min(1, Double(steps.done + 1) / Double(steps.total))
                Circle().inset(by: 2).trim(from: done, to: next)             // the step in hand, faint
                    .stroke(Color.accentColor.opacity(0.35), style: Dots.style(3.0))
                    .rotationEffect(.degrees(-90))
                Circle().inset(by: 2).trim(from: 0, to: done)                // steps finished
                    .stroke(Color.accentColor, style: Dots.style(3.4))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: steps.done)
            } else if working {
                Dots(lineWidth: 2.6).foregroundStyle(Self.grey)
                if let p = progress {
                    Circle().inset(by: 2)
                        .trim(from: 0, to: p)
                        .stroke(Color.accentColor, style: Dots.style(3.4))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: p)
                } else {
                    WaveRing(colors: [.accentColor, Color.accentColor.opacity(0.6)], period: 8)
                }
            } else if waving {
                WaveRing(colors: palette, period: 30)
            } else {
                Dots(lineWidth: 2.6).foregroundStyle(Self.grey)
            }
        }
    }
}

struct Dots: View {
    var lineWidth: CGFloat
    static func style(_ w: CGFloat) -> StrokeStyle {
        let gap = Double.pi * 168 / 72 - 0.01
        return StrokeStyle(lineWidth: w, lineCap: .round, dash: [0.01, gap])
    }
    var body: some View { Circle().inset(by: 2).stroke(style: Self.style(lineWidth)) }
}

/// One ring of dots whose colour blends smoothly round it; the ring itself turns slowly.
struct WaveRing: View {
    let colors: [Color]
    let period: Double
    @State private var angle = 0.0

    private var gradient: AngularGradient {
        // A lone colour fades to a softer copy of itself so the turn is still visible.
        let base = colors.first ?? .accentColor
        let cs = colors.count > 1 ? colors : [base, base.opacity(0.4)]
        return AngularGradient(colors: cs + [cs[0]], center: .center)
    }

    var body: some View {
        Circle().inset(by: 2)
            .stroke(gradient, style: Dots.style(3.2))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// Album art / thumbnail as a blurred, saturated, glassy fill for the circle.
struct GlassArt: View {
    let image: NSImage

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 142, height: 142)
                .scaleEffect(1.5)
                .blur(radius: 22)
                .saturation(1.5)
            Color.black.opacity(0.18)                       // keep white text readable
            LinearGradient(colors: [.white.opacity(0.28), .clear, .white.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// The title set round the circle like the label text on a vinyl, turning slowly.
struct CircularText: View {
    let text: String
    @State private var spin = 0.0

    private var chars: [Character] {
        let base = String(text.prefix(40)) + "  •  "
        let reps = max(1, Int((84.0 / Double(base.count)).rounded()))
        return Array(String(repeating: base, count: reps))
    }

    var body: some View {
        let cs = chars
        ZStack {
            ForEach(0..<cs.count, id: \.self) { i in
                Text(String(cs[i]))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 12, height: 165, alignment: .top)   // char sits at the top, ring centre = frame centre
                    .rotationEffect(.degrees(Double(i) / Double(cs.count) * 360))
            }
        }
        .rotationEffect(.degrees(spin))
        .onAppear {
            withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) { spin = 360 }
        }
    }
}


/// The tick that draws itself, with a soft ring that blooms outward — the "Ready!" moment.
struct ReadyMark: View {
    @State private var drawn = false
    @State private var bloom = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.5), lineWidth: 2)
                .frame(width: 142, height: 142)
                .scaleEffect(bloom ? 1.35 : 1)
                .opacity(bloom ? 0 : 0.8)
            Tick()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .frame(width: 54, height: 40)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.15)) { drawn = true }
            withAnimation(.easeOut(duration: 1.0).delay(0.45)) { bloom = true }
        }
    }
}

struct Tick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.1))
        p.addLine(to: CGPoint(x: r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
