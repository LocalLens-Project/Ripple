import Foundation
@preconcurrency import AVFoundation

struct PreparedVideo {
    let asset: AVAsset
    let plan: TimelinePlan
}

enum VideoTimeline {
    static func prepare(asset: AVAsset, info: VideoInfo, glassEffects: [GlassEffect]) async throws -> PreparedVideo {
        let plan = TimelinePlan(sourceDuration: info.duration, effects: glassEffects)
        guard !plan.spans.isEmpty else { return PreparedVideo(asset: asset, plan: plan) }
        let composition = AVMutableComposition()
        let sourceVideo = try await asset.loadTracks(withMediaType: .video)[0]
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        var audio: [(AVAssetTrack, AVMutableCompositionTrack, CMTimeRange)] = []
        for track in sourceAudio {
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            audio.append((track, target, try await track.load(.timeRange)))
        }
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }
        func insertNormal(from start: Double, to end: Double, at destination: Double) throws {
            guard end - start > 0.000001 else { return }
            let range = CMTimeRange(start: time(start), duration: time(end - start))
            try video.insertTimeRange(range, of: sourceVideo, at: time(destination))
            for (source, target, trackRange) in audio {
                let intersection = CMTimeRangeGetIntersection(range, otherRange: trackRange)
                if intersection.isValid && intersection.duration.seconds > 0 {
                    let offset = intersection.start.seconds - start
                    try target.insertTimeRange(intersection, of: source, at: time(destination + offset))
                }
            }
        }
        var cursor = 0.0
        var output = 0.0
        for span in plan.spans {
            try insertNormal(from: cursor, to: span.sourceTime, at: output)
            output += span.sourceTime - cursor
            let sample = CMTime(value: 1, timescale: 60000)
            try video.insertTimeRange(CMTimeRange(start: time(span.sourceTime), duration: sample), of: sourceVideo, at: time(output))
            video.scaleTimeRange(CMTimeRange(start: time(output), duration: sample), toDuration: time(span.duration))
            for (_, target, _) in audio {
                target.insertEmptyTimeRange(CMTimeRange(start: time(output), duration: time(span.duration)))
            }
            output += span.duration
            cursor = span.sourceTime
        }
        try insertNormal(from: cursor, to: info.duration, at: output)
        return PreparedVideo(asset: composition, plan: plan)
    }
}
