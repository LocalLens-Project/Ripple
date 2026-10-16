import Foundation
import CoreGraphics
import Combine

enum EditorMode: String, CaseIterable, Identifiable {
    case rings, glass
    var id: String { rawValue }
    var title: String { self == .rings ? L10n.text("点击圆环", "Click rings") : L10n.text("玻璃放大", "Glass zoom") }
    var symbol: String { self == .rings ? "circle.circle" : "rectangle.inset.filled.and.person.filled" }
}

@MainActor
final class WorkspaceSettings: ObservableObject {
    @Published var mode: EditorMode?
}

struct GlassEffect: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var duration: Double = 2
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var magnification: Double = 1.32
    var corner: Double = 0.32
    var refraction: Double = 0.65
    var clearBackground: Bool = true

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var timing: GlassTiming { GlassTiming(id: id, start: start, duration: duration) }
    func clamped(sourceDuration: Double) -> GlassEffect {
        var copy = self
        copy.start = min(max(0, start.isFinite ? start : 0), max(0, sourceDuration - 1 / 60000.0))
        copy.duration = min(15, max(0.5, duration.isFinite ? duration : 2))
        copy.width = min(0.96, max(0.02, width.isFinite ? width : 0.5))
        copy.height = min(0.96, max(0.015, height.isFinite ? height : 0.1))
        copy.x = min(1 - copy.width, max(0, x.isFinite ? x : 0.25))
        copy.y = min(1 - copy.height, max(0, y.isFinite ? y : 0.45))
        copy.magnification = min(2.5, max(1.05, magnification.isFinite ? magnification : 1.32))
        copy.corner = min(0.5, max(0, corner.isFinite ? corner : 0.32))
        copy.refraction = min(1, max(0, refraction.isFinite ? refraction : 0.65))
        return copy
    }
}

struct GlassTiming: Equatable, Sendable {
    let id: UUID
    let start: Double
    let duration: Double
}

struct FreezeSpan: Sendable {
    let id: UUID
    let sourceTime: Double
    let outputStart: Double
    let duration: Double
    var outputEnd: Double { outputStart + duration }
}

struct TimelinePlan: Sendable {
    let sourceDuration: Double
    let spans: [FreezeSpan]
    var addedDuration: Double { spans.reduce(0) { $0 + $1.duration } }
    var duration: Double { sourceDuration + addedDuration }

    init(sourceDuration: Double, effects: [GlassEffect]) {
        self.sourceDuration = sourceDuration
        var indexed: [(index: Int, effect: GlassEffect)] = []
        for (index, effect) in effects.enumerated() {
            indexed.append((index, effect.clamped(sourceDuration: sourceDuration)))
        }
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.effect.start == rhs.effect.start { return lhs.index < rhs.index }
            return lhs.effect.start < rhs.effect.start
        }
        var shift = 0.0
        self.spans = sorted.map { _, effect in
            let span = FreezeSpan(id: effect.id, sourceTime: effect.start, outputStart: effect.start + shift, duration: effect.duration)
            shift += effect.duration
            return span
        }
    }

    func sourceTime(at outputTime: Double) -> Double {
        var shift = 0.0
        for span in spans {
            if outputTime < span.outputStart { break }
            if outputTime < span.outputEnd { return span.sourceTime }
            shift += span.duration
        }
        return min(sourceDuration, max(0, outputTime - shift))
    }
    func outputTime(for sourceTime: Double) -> Double {
        sourceTime + spans.filter { $0.sourceTime <= sourceTime }.reduce(0) { $0 + $1.duration }
    }
    func activeSpan(at outputTime: Double) -> FreezeSpan? {
        spans.first { outputTime >= $0.outputStart && outputTime < $0.outputEnd }
    }
    func span(for id: UUID) -> FreezeSpan? { spans.first { $0.id == id } }
}
