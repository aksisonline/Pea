import PeaCore
import Foundation

enum Curve { case linear, easeOut, easeInOut, spring }

func ease(_ c: Curve, _ t: Double) -> Double {
    let t = min(1, max(0, t))
    switch c {
    case .linear: return t
    case .easeOut: return 1 - pow(1 - t, 3)
    case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    case .spring:   // slight overshoot, like SwiftUI's .snappy / bouncy springs
        let c1 = 1.1, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

extension Motion {
    var params: (dur: Double, curve: Curve) {
        switch self {
        case .snappy: return (0.5, .spring)
        case .gentle: return (0.5, .easeInOut)
        case .quick: return (0.35, .easeInOut)
        }
    }
}

/// One animated scalar. Retargeting starts from wherever the value currently is.
struct Chan {
    var from: Double, to: Double
    var t0 = 0.0, dur = 0.0
    var curve = Curve.easeOut
    init(_ v: Double = 0) { from = v; to = v }

    func value(_ now: Double) -> Double {
        guard dur > 0 else { return to }
        return from + (to - from) * ease(curve, (now - t0) / dur)
    }
    func active(_ now: Double) -> Bool { dur > 0 && now - t0 < dur }

    mutating func go(_ target: Double, _ now: Double, _ dur: Double, _ curve: Curve = .easeOut) {
        if target == to { return }
        from = value(now); to = target; t0 = now; self.dur = dur; self.curve = curve
    }
    mutating func snap(_ v: Double) { from = v; to = v; dur = 0 }
}
