import Foundation
@preconcurrency import AVFoundation
import CoreImage

enum VideoRendering {
    static func composition(asset: AVAsset, info: VideoInfo, effects: [ClickEffect], glassEffects: [GlassEffect] = [], plan: TimelinePlan? = nil) async throws -> AVMutableVideoComposition {
        if !glassEffects.isEmpty { try GlassRenderer.validate() }
        let timeline = plan ?? TimelinePlan(sourceDuration: info.duration, effects: glassEffects)
        let context = Ripple.makeContext()
        let bounds = CGRect(origin: .zero, size: info.size)
        let composition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                let outputTime = request.compositionTime.seconds
                var image = Ripple.composite(over: request.sourceImage, at: timeline.sourceTime(at: outputTime), effects: effects, size: info.size)
                if let span = timeline.activeSpan(at: outputTime), let effect = glassEffects.first(where: { $0.id == span.id }) {
                    image = GlassRenderer.composite(over: image, effect: effect, elapsed: outputTime - span.outputStart, size: info.size)
                }
                request.finish(with: image.cropped(to: bounds), context: context)
            }, completionHandler: { result, error in
                if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: error ?? ExportError.message(L10n.text("无法创建视频渲染器。", "Unable to create the video renderer."))) }
            })
        }
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(seconds: 1/Double(max(60, info.fps)), preferredTimescale: 60000)
        composition.renderSize = info.size
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }
}
