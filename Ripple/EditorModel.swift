import SwiftUI
import Combine
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var info: VideoInfo?
    @Published var source: URL?
    @Published var filename = ""
    @Published var effects: [ClickEffect] = []
    @Published var selectedID: UUID?
    @Published var glassEffects: [GlassEffect] = []
    @Published var selectedGlassID: UUID?
    @Published var isDrawingGlass = false
    private var replacingGlassSelection = false
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var isPreparing = false
    @Published var progress = 0.0
    @Published var error: String?
    @Published var exportedURL: URL?
    private var originalAsset: AVAsset?
    private var previewPrepared: PreparedVideo?
    private var previewTimings: [GlassTiming] = []
    private var previewTask: Task<Void, Never>?
    private var compositionVersion = 0
    private var exporter: VideoExporter?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    var selectedIndex: Int? { effects.firstIndex { $0.id == selectedID } }
    var selected: ClickEffect? { selectedIndex.map { effects[$0] } }
    var selectedGlass: GlassEffect? { glassEffects.first { $0.id == selectedGlassID } }
    var busy: Bool { isImporting || isExporting }
    var plan: TimelinePlan { TimelinePlan(sourceDuration: info?.duration ?? 0, effects: glassEffects) }
    var outputDuration: Double { plan.duration }
    var sourceTime: Double { plan.sourceTime(at: currentTime) }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isPreparing else { return }
                self.currentTime = max(0, min(time.seconds, self.outputDuration))
                self.isPlaying = self.player.rate > 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    func cleanup() {
        cancelExport(); pause(); previewTask?.cancel()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        saveDraft()
    }

    func openVideo() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入视频", "Import video")
        panel.prompt = L10n.text("打开", "Open")
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.load(url) }
        }
    }

    func load(_ url: URL) async {
        guard !busy else { return }
        pause(); isImporting = true; exportedURL = nil
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cached = EditSession.directory.appendingPathComponent("source-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.createDirectory(at: EditSession.directory, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: cached) }.value
            let asset = AVURLAsset(url: cached)
            let loaded = try await VideoInfo.load(asset)
            let oldSource = source
            compositionVersion += 1
            previewTask?.cancel()
            previewPrepared = nil; previewTimings = []
            source = cached; info = loaded; filename = url.lastPathComponent; originalAsset = asset
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            effects = []; selectedID = nil; glassEffects = []; selectedGlassID = nil; currentTime = 0
            rebuildPreview()
            saveDraft()
            if let oldSource { try? FileManager.default.removeItem(at: oldSource) }
        } catch {
            try? FileManager.default.removeItem(at: cached)
            self.error = L10n.text("导入失败：", "Import failed: ") + error.localizedDescription
        }
    }

    func pause() { player.pause(); isPlaying = false; saveDraft() }
    func togglePlayback() {
        guard info != nil, !isPreparing else { return }
        if isPlaying { pause() }
        else {
            if currentTime >= outputDuration - 0.02 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func seek(_ value: Double) {
        guard info != nil, value.isFinite else { return }
        currentTime = min(max(value, 0), outputDuration)
        if !isPreparing {
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        saveDraft()
    }
    func step(_ direction: Double) { pause(); seek(currentTime + direction / Double(max(60, info?.fps ?? 60))) }
    func add(at point: CGPoint? = nil) {
        guard let info, !busy else { return }
        pause()
        let start = min(sourceTime, max(0, info.duration - 1 / Double(max(info.fps, 1))))
        let effect = ClickEffect(start: start, duration: min(0.75, info.duration - start), x: Double(point?.x ?? 0.5), y: Double(point?.y ?? 0.5))
        effects.append(effect); selectedID = effect.id; exportedURL = nil
        rebuildPreview()
        seek(plan.outputTime(for: start + effect.duration * 0.25))
        saveDraft()
    }
    func select(_ effect: ClickEffect) {
        pause(); selectedID = effect.id
        seek(plan.outputTime(for: effect.start + min(effect.duration * 0.25, 0.18)))
    }
    func moveEffect(id: UUID, to time: Double) {
        guard !busy, time.isFinite, let info, let index = effects.firstIndex(where: { $0.id == id }) else { return }
        if isPlaying { pause() }
        selectedID = id
        let start = min(max(0, time), max(0, info.duration - effects[index].duration))
        guard abs(effects[index].start - start) > 0.000001 else { return }
        effects[index].start = start
        exportedURL = nil
        rebuildPreview()
        seek(plan.outputTime(for: start))
    }
    func moveRingOnTimeline(id: UUID, to outputTime: Double) { moveEffect(id: id, to: plan.sourceTime(at: outputTime)) }

    func updateSelected(_ update: (inout ClickEffect) -> Void) {
        guard let index = selectedIndex, let info, !busy else { return }
        let previous = effects[index]
        update(&effects[index])
        let minimum = min(1 / Double(max(info.fps, 60)), info.duration)
        effects[index].start = min(max(0, effects[index].start), info.duration - minimum)
        effects[index].duration = min(max(minimum, effects[index].duration), info.duration - effects[index].start)
        effects[index].diameter = min(1.5, max(0.02, effects[index].diameter))
        effects[index].x = min(1, max(0, effects[index].x)); effects[index].y = min(1, max(0, effects[index].y))
        if previous.color != effects[index].color || previous.start != effects[index].start || previous.duration != effects[index].duration || sourceTime < effects[index].start || sourceTime >= effects[index].start + effects[index].duration {
            pause(); currentTime = plan.outputTime(for: effects[index].start + min(0.18, effects[index].duration * 0.25))
        }
        exportedURL = nil
        rebuildPreview()
        seek(currentTime)
    }
    func removeSelected() {
        guard let selectedID else { return }
        effects.removeAll { $0.id == selectedID }; self.selectedID = effects.last?.id; exportedURL = nil
        rebuildPreview(); saveDraft()
    }
    func previewSelected() {
        guard let effect = selected, !isPreparing else { return }
        pause(); seek(plan.outputTime(for: effect.start)); player.play(); isPlaying = true
    }

    func beginGlassSelection(replacing: Bool = false) {
        pause()
        replacingGlassSelection = replacing
        isDrawingGlass = true
        if let id = selectedGlassID, let span = plan.span(for: id), plan.activeSpan(at: currentTime)?.id == id { seek(span.outputEnd) }
    }
    func finishGlassSelection(_ rect: CGRect) {
        if replacingGlassSelection, selectedGlass != nil {
            updateGlass { $0.x = rect.minX; $0.y = rect.minY; $0.width = rect.width; $0.height = rect.height }
        } else { addGlass(rect: rect) }
        replacingGlassSelection = false
        isDrawingGlass = false
    }

    func addGlass(rect: CGRect? = nil) {
        guard let info, !busy else { return }
        pause()
        let area = rect ?? CGRect(x: 0.25, y: 0.45, width: 0.5, height: 0.1)
        let effect = GlassEffect(start: sourceTime, x: area.minX, y: area.minY, width: area.width, height: area.height, corner: 0.5).clamped(sourceDuration: info.duration)
        glassEffects.append(effect); selectedGlassID = effect.id; exportedURL = nil
        rebuildPreview()
        seek((plan.span(for: effect.id)?.outputStart ?? 0) + min(0.5, effect.duration * 0.3))
    }
    func selectGlass(_ effect: GlassEffect) {
        pause(); selectedGlassID = effect.id
        seek((plan.span(for: effect.id)?.outputStart ?? 0) + min(0.5, effect.duration * 0.3))
    }
    func updateGlass(_ update: (inout GlassEffect) -> Void) {
        guard let info, !busy, let index = glassEffects.firstIndex(where: { $0.id == selectedGlassID }) else { return }
        pause()
        update(&glassEffects[index])
        glassEffects[index] = glassEffects[index].clamped(sourceDuration: info.duration)
        let effect = glassEffects[index]
        exportedURL = nil
        rebuildPreview()
        seek((plan.span(for: effect.id)?.outputStart ?? 0) + min(0.5, effect.duration * 0.3))
    }
    func moveGlass(id: UUID, toOutputTime time: Double) {
        guard !busy, time.isFinite, let info, let index = glassEffects.firstIndex(where: { $0.id == id }) else { return }
        let others = TimelinePlan(sourceDuration: info.duration, effects: glassEffects.filter { $0.id != id })
        selectedGlassID = id
        updateGlass { $0.start = others.sourceTime(at: time) }
    }
    func removeGlass() {
        guard let selectedGlassID else { return }
        pause()
        let originalTime = sourceTime
        glassEffects.removeAll { $0.id == selectedGlassID }
        self.selectedGlassID = glassEffects.last?.id
        exportedURL = nil
        rebuildPreview()
        seek(plan.outputTime(for: originalTime))
    }
    func previewGlass() {
        guard let id = selectedGlassID, let span = plan.span(for: id), !isPreparing else { return }
        pause(); seek(max(0, span.outputStart - 0.3)); player.play(); isPlaying = true
    }

    private func saveDraft() {
        guard let source else { return }
        let session = EditSession(source: source, filename: filename, effects: effects, selectedID: selectedID, currentTime: currentTime, glassEffects: glassEffects, selectedGlassID: selectedGlassID)
        do {
            try FileManager.default.createDirectory(at: EditSession.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: EditSession.file, options: .atomic)
        } catch { }
    }

    func restoreDraft() async -> Bool {
        guard let data = try? Data(contentsOf: EditSession.file), let session = try? JSONDecoder().decode(EditSession.self, from: data),
              FileManager.default.fileExists(atPath: session.source.path) else { return false }
        await load(session.source)
        guard source != nil else { return false }
        if session.source != source, session.source.deletingLastPathComponent() == EditSession.directory { try? FileManager.default.removeItem(at: session.source) }
        filename = session.filename
        effects = session.effects
        selectedID = session.selectedID
        glassEffects = (session.glassEffects ?? []).map { $0.clamped(sourceDuration: info?.duration ?? 0) }
        selectedGlassID = session.selectedGlassID
        currentTime = min(session.currentTime, outputDuration)
        rebuildPreview()
        saveDraft()
        return true
    }

    private func rebuildPreview() {
        guard let originalAsset, let info else { return }
        compositionVersion += 1
        let version = compositionVersion
        let rings = effects
        let glasses = glassEffects
        let timings = glasses.map(\.timing)
        let cached = timings == previewTimings ? previewPrepared : nil
        previewTask?.cancel()
        isPreparing = true
        previewTask = Task { [weak self] in
            do {
                let prepared: PreparedVideo
                if let cached { prepared = cached }
                else { prepared = try await VideoTimeline.prepare(asset: originalAsset, info: info, glassEffects: glasses) }
                try Task.checkCancellation()
                let composition = try await VideoRendering.composition(asset: prepared.asset, info: info, effects: rings, glassEffects: glasses, plan: prepared.plan)
                try Task.checkCancellation()
                guard let self, self.compositionVersion == version else { return }
                let resume = self.isPlaying
                if self.player.currentItem?.asset === prepared.asset {
                    self.player.currentItem?.videoComposition = composition
                } else {
                    let item = AVPlayerItem(asset: prepared.asset)
                    item.videoComposition = composition
                    self.player.replaceCurrentItem(with: item)
                }
                self.previewPrepared = prepared; self.previewTimings = timings
                self.isPreparing = false
                self.seek(self.currentTime)
                if resume { self.player.play() }
            } catch is CancellationError {
            } catch {
                guard let self, self.compositionVersion == version else { return }
                self.isPreparing = false
                self.error = L10n.text("预览更新失败：", "Preview failed: ") + error.localizedDescription
            }
        }
    }

    func chooseExport() {
        guard let source, info != nil, !busy else { return }
        pause()
        let panel = NSSavePanel()
        panel.title = L10n.text("导出视频", "Export video")
        panel.prompt = L10n.text("保存", "Save")
        panel.allowedContentTypes = [.quickTimeMovie]
        let suffix = glassEffects.isEmpty ? L10n.text("_点击效果.mov", "_click-effects.mov") : L10n.text("_玻璃放大.mov", "_glass-zoom.mov")
        panel.nameFieldStringValue = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + suffix
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in await self?.export(source: source, destination: destination) }
        }
    }
    private func export(source: URL, destination: URL) async {
        let renderer = VideoExporter(); exporter = renderer
        isExporting = true; progress = 0; exportedURL = nil
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString).mov")
        let rings = effects
        let glasses = glassEffects
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: temporary)
            isExporting = false; exporter = nil
        }
        do {
            try await renderer.export(source: source, to: temporary, effects: rings, glassEffects: glasses) { [self] value in
                Task { @MainActor [self] in self.progress = value }
            }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.copyItem(at: temporary, to: destination) }
            exportedURL = destination
        } catch is CancellationError {
            progress = 0
        } catch { self.error = L10n.text("导出失败：", "Export failed: ") + error.localizedDescription }
    }
    func cancelExport() { exporter?.cancel() }
    func revealExport() { if let exportedURL { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } }
}
