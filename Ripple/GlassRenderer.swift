import Foundation
import CoreImage

struct GlassState {
    let scale: Double
    let visibility: Double
}

enum GlassRenderer {
    private static let compiledKernel: Result<CIKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            throw ExportError.message(L10n.text("缺少玻璃渲染资源，请重新安装应用。", "The glass renderer is missing. Please reinstall the app."))
        }
        return try CIKernel(functionName: "rippleGlass", fromMetalLibraryData: Data(contentsOf: url))
    }

    static func validate() throws { _ = try compiledKernel.get() }

    static func state(elapsed: Double, duration: Double, magnification: Double) -> GlassState {
        guard duration > 0, elapsed > 0, elapsed < duration else { return GlassState(scale: 1, visibility: 0) }
        let entry = min(0.8, duration * 0.36)
        let exit = min(0.85, duration * 0.42)
        let lift: Double
        if elapsed < entry {
            lift = ease(elapsed / entry)
        } else if elapsed > duration - exit {
            lift = ease((duration - elapsed) / exit)
        } else { lift = 1 }
        return GlassState(scale: 1 + (magnification - 1) * lift, visibility: lift)
    }

    private static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func composite(over source: CIImage, effect: GlassEffect, elapsed: Double, size: CGSize) -> CIImage {
        let state = state(elapsed: elapsed, duration: effect.duration, magnification: effect.magnification)
        guard state.visibility > 0, let kernel = try? compiledKernel.get() else { return source }
        let rect = CGRect(x: effect.x * size.width, y: (1 - effect.y - effect.height) * size.height, width: effect.width * size.width, height: effect.height * size.height)
        let padding = min(rect.width, rect.height) * 0.5 + 8
        let target = CGRect(x: rect.midX - rect.width * state.scale / 2, y: rect.midY - rect.height * state.scale / 2, width: rect.width * state.scale, height: rect.height * state.scale)
        let bounds = CGRect(origin: .zero, size: size)
        let extent = target.union(rect).insetBy(dx: -padding, dy: -padding).intersection(bounds)
        let sampleBounds = extent.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        let blur = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(rect.width, rect.height) * 0.055]).cropped(to: bounds)
        guard let patch = kernel.apply(extent: extent, roiCallback: { _, _ in sampleBounds }, arguments: [source, blur, CIVector(cgRect: rect), state.scale, effect.corner, effect.refraction, state.visibility, effect.clearBackground ? 1.0 : 0.0]) else { return source }
        return patch.cropped(to: extent).composited(over: source).cropped(to: bounds)
    }
}
