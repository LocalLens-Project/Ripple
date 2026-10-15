import Foundation
import CoreGraphics
import CoreImage

enum RingColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case white, red, orange, yellow, green, blue, purple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return L10n.text("纯白", "White")
        case .red: return L10n.text("浅红", "Light red")
        case .orange: return L10n.text("浅橙", "Light orange")
        case .yellow: return L10n.text("浅黄", "Light yellow")
        case .green: return L10n.text("浅绿", "Light green")
        case .blue: return L10n.text("浅蓝", "Light blue")
        case .purple: return L10n.text("浅紫", "Light purple")
        }
    }
    var rgb: (red: Double, green: Double, blue: Double) {
        let channels: (Double, Double, Double)
        switch self {
        case .white: channels = (255, 255, 255)
        case .red: channels = (244, 174, 184)
        case .orange: channels = (248, 198, 158)
        case .yellow: channels = (246, 224, 151)
        case .green: channels = (172, 218, 184)
        case .blue: channels = (185, 203, 236)
        case .purple: channels = (205, 184, 235)
        }
        return (channels.0/255, channels.1/255, channels.2/255)
    }
}

struct ClickEffect: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var duration: Double = 0.75
    var x: Double = 0.5
    var y: Double = 0.5
    var diameter: Double = 0.30
    var color: RingColor = .blue
}

struct RingState {
    var scale: Double
    var opacity: Double
}

enum Ripple {
    static func makeContext() -> CIContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space, .outputColorSpace: space])
    }

    static func state(at time: Double, effect: ClickEffect) -> RingState? {
        let elapsed = time - effect.start
        guard effect.duration > 0, elapsed >= 0, elapsed < effect.duration else { return nil }
        let cycles = max(1, Int((effect.duration / 0.75).rounded()))
        let phase = (elapsed / effect.duration * Double(cycles)).truncatingRemainder(dividingBy: 1)
        let scale = interpolate(phase, points: [(0, 0.20), (0.05, 0.60), (0.12, 0.86), (0.26, 0.99), (0.32, 1), (0.56, 0.50), (0.70, 0.58), (1, 0.82)])
        let opacity = interpolate(phase, points: [(0, 0), (0.025, 0.29), (0.075, 0.67), (0.20, 0.94), (0.56, 0.94), (0.72, 0.59), (1, 0)])
        return RingState(scale: scale, opacity: opacity)
    }

    private static func interpolate(_ x: Double, points: [(Double, Double)]) -> Double {
        for i in 1..<points.count where x <= points[i].0 {
            let a = points[i-1], b = points[i]
            let t = max(0, min(1, (x-a.0)/(b.0-a.0)))
            let smooth = t*t*(3-2*t)
            return a.1 + (b.1-a.1)*smooth
        }
        return points.last!.1
    }

    static func geometry(state: RingState, effect: ClickEffect, size: CGSize) -> (center: CGPoint, radius: CGFloat, width: CGFloat) {
        let outer = min(size.width, size.height) * effect.diameter * 0.5 * state.scale
        return (CGPoint(x: effect.x*size.width, y: effect.y*size.height), outer*0.79, outer*0.42)
    }

    static func composite(over source: CIImage, at time: Double, effects: [ClickEffect], size: CGSize) -> CIImage {
        var result = source
        for effect in effects {
            guard let state = state(at: time, effect: effect), state.opacity > 0.001 else { continue }
            let geometry = geometry(state: state, effect: effect, size: size)
            let outer = geometry.radius + geometry.width/2
            let edge = Int(ceil(outer*2))+4
            guard let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let tint = effect.color.rgb
            ctx.setStrokeColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [tint.red, tint.green, tint.blue, state.opacity])!)
            ctx.setLineWidth(geometry.width)
            let mid = CGFloat(edge)/2
            ctx.strokeEllipse(in: CGRect(x: mid-geometry.radius, y: mid-geometry.radius, width: geometry.radius*2, height: geometry.radius*2))
            guard let image = ctx.makeImage() else { continue }
            let ring = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: geometry.center.x-mid, y: size.height-geometry.center.y-mid))
            result = ring.composited(over: result)
        }
        return result
    }
}
