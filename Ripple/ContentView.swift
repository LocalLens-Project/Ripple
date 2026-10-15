import SwiftUI
import Foundation
import AppKit
import AVKit

private let accent = Color(red: 0.38, green: 0.68, blue: 1)
private let panelColor = Color(red: 0.105, green: 0.115, blue: 0.135)

struct ContentView: View {
    @StateObject private var model = EditorModel()
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let info = model.info {
                        preview(info: info)
                        transport
                        timeline
                    } else { welcome }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.info != nil {
                    Divider().opacity(0.5)
                    inspector.frame(width: 284)
                }
            }
            if model.isExporting {
                HStack(spacing: 12) {
                    ProgressView(value: model.progress).tint(accent)
                    Text(L10n.text("正在导出 \(Int(model.progress*100))%", "Exporting \(Int(model.progress*100))%")).monospacedDigit().frame(width: 115)
                    Button(L10n.text("取消", "Cancel")) { model.cancelExport() }
                }.padding(16).background(panelColor)
            }
        }
        .background(Color(red: 0.065, green: 0.075, blue: 0.09))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 940, minHeight: 660)
        .overlay { if model.isImporting { ProgressView(L10n.text("正在读取原视频…", "Loading original video…")).padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert(L10n.text("未能完成", "Unable to complete"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.text("好", "OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDisappear { model.cleanup() }
        .task { _ = await model.restoreDraft() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.circle").font(.system(size: 23, weight: .light)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.appName).font(.system(size: 15, weight: .semibold))
                Text(model.info == nil ? L10n.text("给视频加一个轻盈的点击提示", "Add a gentle click cue to your video") : model.filename).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.exportedURL != nil {
                Button { model.revealExport() } label: { Label(L10n.text("导出完成 · 在 Finder 显示", "Exported · Show in Finder"), systemImage: "checkmark.circle.fill") }
                    .foregroundStyle(.green).buttonStyle(.plain)
            }
            Button { model.openVideo() } label: { Label(model.info == nil ? L10n.text("导入视频", "Import video") : L10n.text("更换视频", "Replace video"), systemImage: "plus") }
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("o").disabled(model.busy)
            Button { model.chooseExport() } label: { Label(L10n.text("导出视频", "Export video"), systemImage: "square.and.arrow.up") }
                .buttonStyle(PrimaryActionStyle())
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("e").disabled(model.info == nil || model.busy)
        }.padding(.horizontal, 22).padding(.vertical, 15).background(panelColor)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.65)
                Canvas { context, size in
                    let effect = ClickEffect(start: 0, duration: 1.2, diameter: 0.9)
                    if let state = Ripple.state(at: time, effect: effect) { drawRing(context: &context, size: size, effect: effect, state: state) }
                }
            }.frame(width: 150, height: 150)
            Text(L10n.text("让每一次点击，都看得见。", "Make every click visible.")).font(.system(size: 26, weight: .medium))
            Text(L10n.text("导入视频，点选位置。呼吸节奏自动完成。", "Import a video and pick a spot. Breathing timing is automatic."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button(L10n.text("选择视频…", "Choose a video…")) { model.openVideo() }.buttonStyle(PrimaryActionStyle()).padding(.top, 6)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preview(info: VideoInfo) -> some View {
        GeometryReader { proxy in
            let scale = min((proxy.size.width-48)/info.size.width, (proxy.size.height-54)/info.size.height)
            let size = CGSize(width: max(1, info.size.width*scale), height: max(1, info.size.height*scale))
            ZStack {
                Color.black.opacity(0.12)
                ZStack {
                    PlayerSurface(player: model.player)
                    if let effect = model.selected {
                        Image(systemName: "plus").font(.system(size: 12, weight: .light)).foregroundStyle(accent)
                            .padding(6).background(.black.opacity(0.35), in: Circle())
                            .position(x: effect.x*size.width, y: effect.y*size.height)
                            .allowsHitTesting(false)
                    }
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            let point = CGPoint(x: tap.location.x/size.width, y: tap.location.y/size.height)
                            model.add(at: point)
                        })
                        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                            guard model.selected != nil else { return }
                            model.pause()
                            model.updateSelected { $0.x = value.location.x/size.width; $0.y = value.location.y/size.height }
                        })
                }.frame(width: size.width, height: size.height).clipped().shadow(color: .black.opacity(0.3), radius: 16, y: 5)
                VStack { Spacer(); Text(model.selected == nil ? L10n.text("点击画面，添加圆环", "Click the video to add a ring") : L10n.text("点击添加新圆环 · 拖动调整选中圆环的位置", "Click to add a ring · Drag to move the selected ring"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transport: some View {
        HStack(spacing: 15) {
            Button { model.step(-1) } label: { Image(systemName: "backward.end.fill") }.help(L10n.text("上一帧", "Previous frame"))
            Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }.keyboardShortcut(.space, modifiers: [])
            Button { model.step(1) } label: { Image(systemName: "forward.end.fill") }.help(L10n.text("下一帧", "Next frame"))
            Text(String(format: "%06.2f / %06.2f s", model.currentTime, model.info?.duration ?? 0)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            if let info = model.info {
                Text("\(Int(info.size.width)) × \(Int(info.size.height))  ·  \(String(format: "%.2f", info.fps)) fps")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 12).disabled(model.busy)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Slider(value: Binding(get: { model.currentTime }, set: { model.pause(); model.seek($0) }), in: 0...max(0.001, model.info?.duration ?? 1)).tint(accent)
                .accessibilityLabel(L10n.text("视频时间", "Video time"))
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.045))
                    ForEach(Array(model.effects.enumerated()), id: \.element.id) { index, effect in
                        let total = max(0.001, model.info?.duration ?? 1)
                        EffectTimelineBar(model: model, effect: effect, index: index, trackWidth: proxy.size.width, totalDuration: total)
                            .frame(width: max(8, proxy.size.width*effect.duration/total), height: 25)
                            .offset(x: proxy.size.width*effect.start/total, y: CGFloat(index%2)*8+3)
                            .zIndex(effect.id == model.selectedID ? 1 : 0)
                    }
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 1).offset(x: proxy.size.width*model.currentTime/max(0.001, model.info?.duration ?? 1))
                        .allowsHitTesting(false)
                }.coordinateSpace(name: "effectTrack").clipped()
            }.frame(height: 42)
            HStack {
                Text(L10n.effectCount(model.effects.count)).foregroundStyle(.secondary)
                Spacer()
                Button { model.add() } label: { Label(L10n.text("在当前时间添加", "Add at current time"), systemImage: "plus.circle") }
            }.font(.system(size: 11)).buttonStyle(.plain)
        }.padding(.horizontal, 24).padding(.bottom, 22).disabled(model.busy)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(L10n.text("点击效果", "Click effects")).font(.system(size: 16, weight: .semibold)); Spacer(); Text("\(model.effects.count)").foregroundStyle(.secondary) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let effect = model.selected {
                        HStack { Image(systemName: "circle").foregroundStyle(accent); Text(L10n.text("\(effect.color.title)呼吸圆环", "\(effect.color.title) breathing ring")).font(.system(size: 13, weight: .medium)); Spacer() }
                        timeControl(L10n.text("出现时间", "Start time"), value: Binding(get: { model.selected?.start ?? 0 }, set: { model.moveEffect(id: effect.id, to: $0) }), range: 0...max(0, (model.info?.duration ?? 1)-effect.duration))
                        timeControl(L10n.text("持续时长", "Duration"), value: binding(\.duration), range: min(1/Double(max(60, model.info?.fps ?? 60)), (model.info?.duration ?? 1)-effect.start)...max(0.001, (model.info?.duration ?? 1)-effect.start))
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(L10n.text("圆环大小", "Ring size")); Spacer(); Text("\(Int(effect.diameter*100))%").monospacedDigit().foregroundStyle(.secondary) }
                            Slider(value: binding(\.diameter), in: 0.02...1.5).tint(accent).accessibilityLabel(L10n.text("圆环最大直径", "Maximum ring diameter"))
                            Text(L10n.text("最大外径，占视频短边的比例", "Maximum diameter as a share of the shorter video edge")).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L10n.text("颜色", "Color"))
                                Spacer()
                                Text(effect.color.title).foregroundStyle(.secondary)
                            }.font(.system(size: 12))
                            HStack(spacing: 8) {
                                ForEach(RingColor.allCases) { choice in
                                    Button {
                                        model.updateSelected { $0.color = choice }
                                    } label: {
                                        Circle().fill(choice.swatch)
                                            .frame(width: 22, height: 22)
                                            .overlay {
                                                if effect.color == choice {
                                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                                                }
                                            }
                                            .padding(3)
                                            .overlay(Circle().stroke(effect.color == choice ? accent : .clear, lineWidth: 1.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help(choice.title)
                                    .accessibilityLabel(choice.title)
                                    .accessibilityValue(effect.color == choice ? L10n.text("已选中", "Selected") : L10n.text("未选中", "Not selected"))
                                }
                            }
                        }
                        Text(L10n.breathSummary(max(1, Int((effect.duration/0.75).rounded()))))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        Button { model.previewSelected() } label: { Label(L10n.text("预览这次点击", "Preview this click"), systemImage: "play.circle").frame(maxWidth: .infinity) }.controlSize(.large)
                        Button(role: .destructive) { model.removeSelected() } label: { Label(L10n.text("删除圆环", "Delete ring"), systemImage: "trash").frame(maxWidth: .infinity) }.buttonStyle(.plain).foregroundStyle(.red.opacity(0.85)).font(.system(size: 11))
                    } else {
                        Image(systemName: "cursorarrow.click").font(.system(size: 24, weight: .light)).foregroundStyle(accent).padding(.top, 12)
                        Text(L10n.text("停在需要的时间，\n点击画面添加圆环。", "Pause at the desired time,\nthen click the video to add a ring.")).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                        Button { model.add() } label: { Label(L10n.text("添加圆环", "Add a ring"), systemImage: "plus") }
                    }
                    if !model.effects.isEmpty {
                        Divider()
                        Text(L10n.text("所有圆环", "All rings")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(Array(model.effects.enumerated()), id: \.element.id) { index, effect in
                            Button { model.select(effect) } label: {
                                HStack {
                                    Text(String(format: "%02d", index+1)).foregroundStyle(accent)
                                    Text(String(format: "%.2f s", effect.start)); Spacer()
                                    Text(L10n.seconds(effect.duration)).foregroundStyle(.secondary)
                                }.font(.system(size: 12, design: .monospaced)).padding(10)
                                    .background(effect.id == model.selectedID ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(20)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("原始分辨率导出", "Export at original resolution"), systemImage: "checkmark.shield").font(.system(size: 11, weight: .medium))
                Text(model.info?.isHDR == true ? L10n.text("此视频为 HDR；当前导出为 SDR，保留原像素尺寸与时长。", "This is HDR video. Export uses SDR with the original dimensions and duration.") : L10n.text("原像素尺寸、原时长和音轨。\n动画至少 60 fps，预览与导出共用渲染器。", "Original dimensions, duration and audio.\nAnimation renders at 60 fps or higher, using the same renderer as the preview."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(20)
        }.background(panelColor).disabled(model.busy)
    }

    private func binding(_ keyPath: WritableKeyPath<ClickEffect, Double>) -> Binding<Double> {
        Binding(get: { model.selected?[keyPath: keyPath] ?? 0 }, set: { value in model.updateSelected { $0[keyPath: keyPath] = value } })
    }
    private func timeControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title); Spacer()
                Text(L10n.seconds(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).tint(accent).accessibilityLabel(title)
        }.font(.system(size: 12))
    }
    private func drawRing(context: inout GraphicsContext, size: CGSize, effect: ClickEffect, state: RingState) {
        let g = Ripple.geometry(state: state, effect: effect, size: size)
        let rect = CGRect(x: g.center.x-g.radius, y: g.center.y-g.radius, width: g.radius*2, height: g.radius*2)
        context.stroke(Path(ellipseIn: rect), with: .color(effect.color.swatch.opacity(state.opacity)), lineWidth: g.width)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { if nsView.player !== player { nsView.player = player } }
}

private extension RingColor {
    var swatch: Color {
        let tint = rgb
        return Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue)
    }
}

private struct EffectTimelineBar: View {
    @ObservedObject var model: EditorModel
    let effect: ClickEffect
    let index: Int
    let trackWidth: CGFloat
    let totalDuration: Double
    @State private var dragStart: Double?

    var body: some View {
        Text("\(index+1)")
            .font(.system(size: 10, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(effect.id == model.selectedID ? accent : accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(effect.id == model.selectedID ? .black : .white)
            .contentShape(Rectangle())
            .onTapGesture { model.select(effect) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("effectTrack"))
                .onChanged { value in
                    if dragStart == nil { dragStart = effect.start }
                    move(value.translation.width)
                }
                .onEnded { value in
                    move(value.translation.width)
                    dragStart = nil
                })
            .accessibilityElement()
            .accessibilityLabel(L10n.text("圆环 \(index+1)", "Ring \(index+1)"))
            .accessibilityValue(String(format: L10n.text("%.2f 秒开始，持续 %.2f 秒", "Starts at %.2f s, lasts %.2f s"), effect.start, effect.duration))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.select(effect) }
            .help(String(format: L10n.text("圆环 %d · %.2f s 开始 · 持续 %.2f s · 左右拖动调整时间", "Ring %d · Starts at %.2f s · Lasts %.2f s · Drag left or right to change the start time"), index+1, effect.start, effect.duration))
    }

    private func move(_ translation: CGFloat) {
        guard let dragStart, trackWidth > 0 else { return }
        model.moveEffect(id: effect.id, to: dragStart + Double(translation/trackWidth)*totalDuration)
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.045, green: 0.09, blue: 0.16))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
