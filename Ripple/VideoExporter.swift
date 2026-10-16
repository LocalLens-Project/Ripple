import Foundation
@preconcurrency import AVFoundation
import CoreImage
import VideoToolbox

struct VideoInfo {
    let duration: Double
    let size: CGSize
    let fps: Float
    let bitrate: Float
    let transform: CGAffineTransform
    let isHDR: Bool

    static func load(_ asset: AVAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.message(L10n.text("这个文件没有视频轨道。", "This file has no video track.")) }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let formats = try await track.load(.formatDescriptions)
        let hdr = formats.contains { description in
            let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
            return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        }
        guard duration.isFinite, duration > 0, rect.width > 0, rect.height > 0 else { throw ExportError.message(L10n.text("视频的时长或尺寸无效。", "The video duration or dimensions are invalid.")) }
        return VideoInfo(duration: duration, size: CGSize(width: abs(rect.width), height: abs(rect.height)),
                         fps: try await track.load(.nominalFrameRate), bitrate: try await track.load(.estimatedDataRate), transform: transform, isHDR: hdr)
    }
}

enum ExportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class ExportPipeline: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoIn: AVAssetWriterInput
    let videoOut: AVAssetReaderVideoCompositionOutput
    let adapter: AVAssetWriterInputPixelBufferAdaptor
    let audio: [(AVAssetReaderOutput, AVAssetWriterInput)]
    init(reader: AVAssetReader, writer: AVAssetWriter, videoIn: AVAssetWriterInput,
         videoOut: AVAssetReaderVideoCompositionOutput, adapter: AVAssetWriterInputPixelBufferAdaptor,
         audio: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader; self.writer = writer; self.videoIn = videoIn
        self.videoOut = videoOut; self.adapter = adapter; self.audio = audio
    }
}

final class VideoExporter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var firstError: Error?
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || firstError != nil }
    private func fail(_ error: Error) { lock.lock(); if firstError == nil { firstError = error }; lock.unlock() }
    private func recordedError() -> Error? { lock.lock(); defer { lock.unlock() }; return firstError }

    func export(source: URL, to destination: URL, effects: [ClickEffect], glassEffects: [GlassEffect] = [], progress: @escaping @Sendable (Double) -> Void) async throws {
        let original = AVURLAsset(url: source)
        let info = try await VideoInfo.load(original)
        let prepared = try await VideoTimeline.prepare(asset: original, info: info, glassEffects: glassEffects)
        let asset = prepared.asset
        let duration = prepared.plan.duration
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first!
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = try await VideoRendering.composition(asset: asset, info: info, effects: effects, glassEffects: glassEffects, plan: prepared.plan)
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError.message(L10n.text("无法读取视频。", "Unable to read the video.")) }
        reader.add(videoOut)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let width = Int(info.size.width.rounded()), height = Int(info.size.height.rounded())
        let rate = max(Double(info.bitrate)*1.5, Double(width*height)*Double(max(info.fps, 60))*0.16)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(rate), AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                               AVVideoAllowFrameReorderingKey: false]
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.mediaTimeScale = max(60000, try await videoTrack.load(.naturalTimeScale))
        guard writer.canAdd(videoIn) else { throw ExportError.message(L10n.text("编码器不支持这个视频尺寸。", "The encoder does not support these video dimensions.")) }
        writer.add(videoIn)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        var audioPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let formats = try await track.load(.formatDescriptions)
            let out: AVAssetReaderOutput
            let input: AVAssetWriterInput
            if glassEffects.isEmpty {
                out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            } else {
                let format = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = Int(format?.mChannelsPerFrame ?? 2)
                let sampleRate = format?.mSampleRate ?? 48000
                out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: sampleRate, AVEncoderBitRateKey: min(320000, 96000 * channels)])
            }
            guard reader.canAdd(out), writer.canAdd(input) else { throw ExportError.message(L10n.text("无法保留这个视频的音轨。", "Unable to preserve this video’s audio tracks.")) }
            reader.add(out); writer.add(input); audioPairs.append((out, input))
        }
        var success = false
        defer {
            if !success {
                reader.cancelReading(); writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
            }
        }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? ExportError.message(L10n.text("无法开始导出。", "Unable to start the export.")) }
        writer.startSession(atSourceTime: .zero)
        let pipeline = ExportPipeline(reader: reader, writer: writer, videoIn: videoIn, videoOut: videoOut, adapter: adapter, audio: audioPairs)
        let group = DispatchGroup()
        group.enter()
        let videoQueue = DispatchQueue(label: "click.export.video", qos: .userInitiated)
        videoQueue.async { [self] in
            defer { pipeline.videoIn.markAsFinished(); group.leave() }
            while !shouldStop {
                if pipeline.reader.status == .failed || pipeline.writer.status == .failed {
                    fail(pipeline.reader.error ?? pipeline.writer.error ?? ExportError.message(L10n.text("视频读写失败。", "Unable to read or write the video."))); return
                }
                guard pipeline.videoIn.isReadyForMoreMediaData else { Thread.sleep(forTimeInterval: 0.002); continue }
                guard let sample = pipeline.videoOut.copyNextSampleBuffer() else { return }
                autoreleasepool {
                    do {
                        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw ExportError.message(L10n.text("无法读取渲染帧。", "Unable to read a rendered frame.")) }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard pipeline.adapter.append(pixel, withPresentationTime: timestamp) else { throw pipeline.writer.error ?? ExportError.message(L10n.text("写入视频帧失败。", "Unable to write a video frame.")) }
                        progress(min(0.99, timestamp.seconds/duration))
                    } catch { fail(error) }
                }
            }
        }
        for index in pipeline.audio.indices {
            group.enter()
            DispatchQueue(label: "click.export.audio.\(index)").async { [self] in
                let pair = pipeline.audio[index]
                defer { pair.1.markAsFinished(); group.leave() }
                while !shouldStop {
                    if pipeline.reader.status == .failed || pipeline.writer.status == .failed {
                        fail(pipeline.reader.error ?? pipeline.writer.error ?? ExportError.message(L10n.text("音轨读写失败。", "Unable to read or write the audio."))); return
                    }
                    guard pair.1.isReadyForMoreMediaData else { Thread.sleep(forTimeInterval: 0.002); continue }
                    guard let sample = pair.0.copyNextSampleBuffer() else { return }
                    if !pair.1.append(sample) { fail(pipeline.writer.error ?? ExportError.message(L10n.text("写入音轨失败。", "Unable to write the audio track."))); return }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        if let error = recordedError() { throw error }
        if shouldStop { throw CancellationError() }
        if reader.status == .failed { throw reader.error ?? ExportError.message(L10n.text("读取视频失败。", "Unable to read the video.")) }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.message(L10n.text("导出未完成。", "The export did not complete.")) }
        success = true
        progress(1)
    }
}
