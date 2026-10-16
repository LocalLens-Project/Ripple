import SwiftUI

private let glassAccent = Color(red: 0.38, green: 0.68, blue: 1)
private let glassPanel = Color(red: 0.105, green: 0.115, blue: 0.135)

struct GlassSelectionOverlay: View {
    @ObservedObject var model: EditorModel
    let size: CGSize
    @State private var pending: CGRect?
    @State private var initial: CGRect?
    @State private var corner: Int?

    private var drawing: Bool { model.isDrawingGlass || model.selectedGlass == nil }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if let rect = pending ?? model.selectedGlass?.rect {
                let displayed = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
                RoundedRectangle(cornerRadius: 5).strokeBorder(glassAccent.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: drawing ? [5, 3] : []))
                    .frame(width: displayed.width, height: displayed.height).offset(x: displayed.minX, y: displayed.minY)
                if !drawing {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 2).fill(glassAccent).frame(width: 7, height: 7)
                            .position(x: index % 2 == 0 ? displayed.minX : displayed.maxX, y: index < 2 ? displayed.minY : displayed.maxY)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                let point = normalized(value.location)
                let start = normalized(value.startLocation)
                if drawing {
                    pending = CGRect(x: min(point.x, start.x), y: min(point.y, start.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
                } else if let selected = model.selectedGlass {
                    if initial == nil {
                        initial = selected.rect
                        let corners = [CGPoint(x: selected.x, y: selected.y), CGPoint(x: selected.x + selected.width, y: selected.y), CGPoint(x: selected.x, y: selected.y + selected.height), CGPoint(x: selected.x + selected.width, y: selected.y + selected.height)]
                        corner = corners.firstIndex { hypot(($0.x - start.x) * size.width, ($0.y - start.y) * size.height) < 15 }
                    }
                    guard let initial else { return }
                    var area = initial
                    if let corner {
                        let opposite = CGPoint(x: corner % 2 == 0 ? initial.maxX : initial.minX, y: corner < 2 ? initial.maxY : initial.minY)
                        area = CGRect(x: min(point.x, opposite.x), y: min(point.y, opposite.y), width: max(0.02, abs(point.x - opposite.x)), height: max(0.015, abs(point.y - opposite.y)))
                    } else if initial.insetBy(dx: -0.02, dy: -0.02).contains(start) {
                        area.origin.x += point.x - start.x
                        area.origin.y += point.y - start.y
                    } else { return }
                    model.updateGlass { $0.x = area.minX; $0.y = area.minY; $0.width = area.width; $0.height = area.height }
                }
            }
            .onEnded { _ in
                if drawing, let pending, pending.width >= 0.02, pending.height >= 0.015 { model.finishGlassSelection(pending) }
                pending = nil; initial = nil; corner = nil
            })
        .accessibilityLabel(L10n.text("框选玻璃放大区域", "Draw a glass zoom region"))
    }
    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }
}

struct GlassInspector: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("玻璃放大", "Glass zoom")).font(.system(size: 16, weight: .semibold))
                Spacer(); Text("\(model.glassEffects.count)").foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    if let effect = model.selectedGlass {
                        control(L10n.text("原片插入位置", "Source insertion time"), value: binding(\.start), range: 0...max(0.0001, (model.info?.duration ?? 1) - 1 / 60000), step: 1 / 60, label: L10n.seconds(effect.start))
                        control(L10n.text("静止时长", "Freeze duration"), value: binding(\.duration), range: 0.5...15, step: 1 / 60, label: L10n.seconds(effect.duration))
                        Text(L10n.text("新增这段时间播放放大动画，原片与音轨暂停，后面内容整体顺延。", "This time is added for the animation. The original video and audio pause, and later content shifts together."))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                        control(L10n.text("放大倍率", "Magnification"), value: binding(\.magnification), range: 1.05...2.5, step: 0.01, label: String(format: "%.2f×", effect.magnification))
                        HStack {
                            Button(L10n.text("重新框选", "Redraw region")) { model.beginGlassSelection(replacing: true) }
                            Button(L10n.text("再加一个", "Add another")) { model.beginGlassSelection() }
                        }.controlSize(.small)
                        DisclosureGroup(L10n.text("选区与玻璃外观", "Region and glass appearance")) {
                            VStack(spacing: 16) {
                                control(L10n.text("选区宽度", "Region width"), value: binding(\.width), range: 0.02...0.96, step: 0.002, label: String(format: "%.1f%%", effect.width * 100))
                                control(L10n.text("选区高度", "Region height"), value: binding(\.height), range: 0.015...0.96, step: 0.001, label: String(format: "%.1f%%", effect.height * 100))
                                control(L10n.text("圆角", "Corner radius"), value: binding(\.corner), range: 0...0.5, step: 0.01, label: String(format: "%.0f%%", effect.corner * 200))
                                control(L10n.text("折射强度", "Refraction"), value: binding(\.refraction), range: 0...1, step: 0.01, label: String(format: "%.0f%%", effect.refraction * 100))
                                Toggle(L10n.text("浅色底透明玻璃", "Clear glass for light backgrounds"), isOn: Binding(get: { model.selectedGlass?.clearBackground ?? true }, set: { value in model.updateGlass { $0.clearBackground = value } }))
                                    .font(.system(size: 11))
                            }.padding(.top, 14)
                        }.font(.system(size: 12))
                        Button { model.previewGlass() } label: {
                            Label(L10n.text("预览这次放大", "Preview this zoom"), systemImage: "play.circle").frame(maxWidth: .infinity)
                        }.controlSize(.large).disabled(model.isPreparing)
                        Button(role: .destructive) { model.removeGlass() } label: {
                            Label(L10n.text("删除这次放大", "Delete zoom"), systemImage: "trash").frame(maxWidth: .infinity)
                        }.buttonStyle(.plain).foregroundStyle(.red.opacity(0.85)).font(.system(size: 11))
                    } else {
                        Image(systemName: "rectangle.dashed").font(.system(size: 27, weight: .light)).foregroundStyle(glassAccent).padding(.top, 10)
                        Text(L10n.text("停在需要的位置，\n拖动画面框选要放大的区域。", "Pause at the desired moment,\nthen draw a region on the video."))
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                        Button(L10n.text("框选放大区域", "Draw a zoom region")) { model.beginGlassSelection() }
                    }
                    if !model.glassEffects.isEmpty {
                        Divider()
                        Text(L10n.text("所有定格片段", "Freeze segments")).font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Array(model.glassEffects.enumerated()), id: \.element.id) { index, effect in
                            Button { model.selectGlass(effect) } label: {
                                HStack {
                                    Text(String(format: "%02d", index + 1)).foregroundStyle(glassAccent)
                                    Text(String(format: "%.2f s", effect.start)); Spacer()
                                    Text("+" + L10n.seconds(effect.duration)).foregroundStyle(.secondary)
                                }.font(.system(size: 12, design: .monospaced)).padding(10)
                                    .background(effect.id == model.selectedGlassID ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("原始分辨率导出", "Export at original resolution"), systemImage: "checkmark.shield").font(.system(size: 11, weight: .medium))
                Text(L10n.text("原片 ", "Original ") + L10n.seconds(model.info?.duration ?? 0) + " + " + L10n.seconds(model.plan.addedDuration) + " = " + L10n.seconds(model.outputDuration))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Text(model.info?.isHDR == true ? L10n.text("HDR 输入当前导出为 SDR。定格段静音，结束后音画同步继续。", "HDR exports as SDR. Freeze segments are silent; video and audio resume together.") : L10n.text("定格段静音，结束后音画同步继续。预览与导出共用玻璃渲染器。", "Freeze segments are silent. Video and audio resume together. Preview and export share the glass renderer."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                Divider().padding(.vertical, 4)
                RepositoryLink()
            }.padding(20)
        }.background(glassPanel).disabled(model.busy)
    }
    private func binding(_ keyPath: WritableKeyPath<GlassEffect, Double>) -> Binding<Double> {
        Binding(get: { model.selectedGlass?[keyPath: keyPath] ?? 0 }, set: { value in model.updateGlass { $0[keyPath: keyPath] = value } })
    }
    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(spacing: 9) {
            HStack { Text(title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).tint(glassAccent).accessibilityLabel(title)
        }.font(.system(size: 12))
    }
}

struct GlassTimeline: View {
    @ObservedObject var model: EditorModel
    @State private var draggedID: UUID?
    @State private var dragStart = 0.0
    @State private var dragDuration = 0.0
    var body: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { model.currentTime }, set: { model.pause(); model.seek($0) }), in: 0...max(0.001, model.outputDuration))
                .tint(glassAccent).accessibilityLabel(L10n.text("视频时间", "Video time"))
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.045))
                    ForEach(Array(model.plan.spans.enumerated()), id: \.element.id) { index, span in
                        GlassTimelineBar(model: model, span: span, index: index)
                            .frame(width: max(8, proxy.size.width * span.duration / max(0.001, model.outputDuration)), height: 30)
                            .offset(x: proxy.size.width * span.outputStart / max(0.001, model.outputDuration), y: 4)
                    }
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 1).offset(x: proxy.size.width * model.currentTime / max(0.001, model.outputDuration)).allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .coordinateSpace(name: "glassTrack")
                .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("glassTrack"))
                    .onChanged { value in
                        if draggedID == nil {
                            let time = Double(value.startLocation.x / max(1, proxy.size.width)) * model.outputDuration
                            guard let span = model.plan.activeSpan(at: time) else { return }
                            draggedID = span.id; dragStart = span.outputStart; dragDuration = model.outputDuration
                        }
                        move(value.translation.width, width: proxy.size.width)
                    }
                    .onEnded { value in
                        move(value.translation.width, width: proxy.size.width)
                        draggedID = nil
                    })
                .clipped()
            }.frame(height: 42)
            HStack {
                Text(L10n.text("新增定格 ", "Added freeze time ") + L10n.seconds(model.plan.addedDuration)).foregroundStyle(.secondary)
                Spacer()
                Button { model.beginGlassSelection() } label: {
                    Label(L10n.text("框选放大区域", "Draw a zoom region"), systemImage: "rectangle.dashed")
                }
            }.font(.system(size: 11)).buttonStyle(.plain)
        }.padding(.horizontal, 24).padding(.bottom, 22).disabled(model.busy)
    }
    private func move(_ translation: CGFloat, width: CGFloat) {
        guard let draggedID, width > 0 else { return }
        model.moveGlass(id: draggedID, toOutputTime: dragStart + Double(translation / width) * dragDuration)
    }
}

private struct GlassTimelineBar: View {
    @ObservedObject var model: EditorModel
    let span: FreezeSpan
    let index: Int
    var body: some View {
        barLabel
            .onTapGesture(perform: select)
            .accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel(L10n.text("定格 \(index + 1)", "Freeze \(index + 1)"))
            .accessibilityValue(accessibleValue)
            .accessibilityAction { select() }
    }
    private var barLabel: some View {
        Text("\(index + 1)  ❄︎").font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(span.id == model.selectedGlassID ? glassAccent : glassAccent.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(span.id == model.selectedGlassID ? Color.black : Color.white)
            .contentShape(Rectangle())
    }
    private var accessibleValue: String {
        L10n.text("原片 ", "Source ") + L10n.seconds(span.sourceTime) + " + " + L10n.seconds(span.duration)
    }
    private func select() {
        if let effect = model.glassEffects.first(where: { $0.id == span.id }) { model.selectGlass(effect) }
    }
}
