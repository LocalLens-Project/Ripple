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
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var progress = 0.0
    @Published var error: String?
    @Published var exportedURL: URL?
    private var compositionVersion = 0
    private var exporter: VideoExporter?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    var selectedIndex: Int? { effects.firstIndex { $0.id == selectedID } }
    var selected: ClickEffect? { selectedIndex.map { effects[$0] } }
    var busy: Bool { isImporting || isExporting }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = max(0, min(time.seconds, self.info?.duration ?? 0))
                self.isPlaying = self.player.rate > 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    func cleanup() {
        cancelExport(); pause()
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
            source = cached; info = loaded; filename = url.lastPathComponent
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            effects = []; selectedID = nil; currentTime = 0
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
        guard let info else { return }
        if isPlaying { pause() }
        else {
            if currentTime >= info.duration-0.02 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func seek(_ value: Double) {
        guard let info else { return }
        currentTime = min(max(value, 0), info.duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func step(_ direction: Double) { pause(); seek(currentTime + direction/Double(max(info?.fps ?? 60, 1))) }
    func add(at point: CGPoint? = nil) {
        guard let info, !busy else { return }
        pause()
        let start = min(currentTime, max(0, info.duration-1/Double(max(info.fps, 1))))
        let effect = ClickEffect(start: start, duration: min(0.75, info.duration-start), x: Double(point?.x ?? 0.5), y: Double(point?.y ?? 0.5))
        effects.append(effect); selectedID = effect.id; exportedURL = nil
        rebuildPreview()
        seek(start + effect.duration*0.25)
        saveDraft()
    }
    func select(_ effect: ClickEffect) { pause(); selectedID = effect.id; seek(effect.start + min(effect.duration*0.25, 0.18)); saveDraft() }
    func moveEffect(id: UUID, to time: Double) {
        guard !busy, time.isFinite, let info, let index = effects.firstIndex(where: { $0.id == id }) else { return }
        if isPlaying { pause() }
        selectedID = id
        let start = min(max(0, time), max(0, info.duration-effects[index].duration))
        guard abs(effects[index].start-start) > 0.000001 else { return }
        effects[index].start = start
        exportedURL = nil
        rebuildPreview()
        seek(start)
        saveDraft()
    }

    func updateSelected(_ update: (inout ClickEffect) -> Void) {
        guard let index = selectedIndex, let info, !busy else { return }
        let previous = effects[index]
        update(&effects[index])
        let minimum = min(1/Double(max(info.fps, 60)), info.duration)
        effects[index].start = min(max(0, effects[index].start), info.duration-minimum)
        effects[index].duration = min(max(minimum, effects[index].duration), info.duration-effects[index].start)
        effects[index].diameter = min(1.5, max(0.02, effects[index].diameter))
        effects[index].x = min(1, max(0, effects[index].x)); effects[index].y = min(1, max(0, effects[index].y))
        if previous.color != effects[index].color || previous.start != effects[index].start || previous.duration != effects[index].duration || currentTime < effects[index].start || currentTime >= effects[index].start+effects[index].duration {
            pause(); seek(effects[index].start + min(0.18, effects[index].duration*0.25))
        }
        exportedURL = nil
        rebuildPreview()
        saveDraft()
    }
    func removeSelected() {
        guard let selectedID else { return }
        effects.removeAll { $0.id == selectedID }; self.selectedID = effects.last?.id; exportedURL = nil
        rebuildPreview()
        saveDraft()
    }
    func previewSelected() {
        guard let effect = selected else { return }
        pause(); seek(effect.start); player.play(); isPlaying = true
    }

    private func saveDraft() {
        guard let source else { return }
        let session = EditSession(source: source, filename: filename, effects: effects, selectedID: selectedID, currentTime: currentTime)
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
        if session.source != source, session.source.deletingLastPathComponent() == EditSession.directory {
            try? FileManager.default.removeItem(at: session.source)
        }
        filename = session.filename
        effects = session.effects
        selectedID = session.selectedID
        rebuildPreview()
        seek(session.currentTime)
        saveDraft()
        return true
    }

    private func rebuildPreview() {
        guard let item = player.currentItem, let info else { return }
        compositionVersion += 1
        let version = compositionVersion
        let snapshot = effects
        Task { [weak self] in
            do {
                let composition = try await VideoRendering.composition(asset: item.asset, info: info, effects: snapshot)
                guard let self, self.compositionVersion == version, self.player.currentItem === item else { return }
                item.videoComposition = composition
                if !self.isPlaying { self.seek(self.currentTime) }
            } catch { self?.error = L10n.text("预览更新失败：", "Preview failed: ") + error.localizedDescription }
        }
    }

    func chooseExport() {
        guard let source, info != nil, !busy else { return }
        pause()
        let panel = NSSavePanel()
        panel.title = L10n.text("导出视频", "Export video")
        panel.prompt = L10n.text("保存", "Save")
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + L10n.text("_点击效果.mov", "_click-effects.mov")
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                await self.export(source: source, destination: destination)
            }
        }
    }
    private func export(source: URL, destination: URL) async {
        let renderer = VideoExporter(); exporter = renderer
        isExporting = true; progress = 0; exportedURL = nil
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString).mov")
        let snapshot = effects
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: temporary)
            isExporting = false; exporter = nil
        }
        do {
            try await renderer.export(source: source, to: temporary, effects: snapshot) { [self] value in
                Task { @MainActor [self] in self.progress = value }
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.copyItem(at: temporary, to: destination) }
            exportedURL = destination
        } catch is CancellationError {
            progress = 0
        } catch { self.error = L10n.text("导出失败：", "Export failed: ") + error.localizedDescription }
    }
    func cancelExport() { exporter?.cancel() }
    func revealExport() { if let exportedURL { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } }
}
