import SwiftUI

struct ModeSelectionView: View {
    @EnvironmentObject private var settings: WorkspaceSettings
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text(L10n.appName).font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                Text(L10n.text("选择编辑模式", "Choose an editing mode")).font(.system(size: 30, weight: .semibold))
            }
            HStack(spacing: 22) {
                card(.rings, subtitle: L10n.text("点选位置，为视频添加呼吸圆环。", "Mark a click with a breathing ring."))
                card(.glass, subtitle: L10n.text("框选重点，插入定格与玻璃放大。", "Freeze a moment and magnify it in glass."))
            }
            VStack(spacing: 10) {
                Text(L10n.text("稍后可在设置中切换模式，当前编辑会保留。", "Switch modes later in Settings. Your current edit is kept."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                RepositoryLink()
            }
        }
        .frame(minWidth: 940, maxWidth: .infinity, minHeight: 660, maxHeight: .infinity)
        .background(Color(red: 0.065, green: 0.075, blue: 0.09))
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }
    private func card(_ mode: EditorMode, subtitle: String) -> some View {
        Button { settings.mode = mode } label: {
            VStack(spacing: 22) {
                ZStack {
                    if mode == .rings {
                        Circle().stroke(Color.blue.opacity(0.18), lineWidth: 3).frame(width: 122, height: 122)
                        Circle().stroke(Color(red: 0.72, green: 0.8, blue: 0.93), lineWidth: 19).frame(width: 77, height: 77)
                    } else {
                        RoundedRectangle(cornerRadius: 17).fill(.white.opacity(0.08)).frame(width: 132, height: 86).offset(x: 13, y: -9)
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.1)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.55), lineWidth: 1.5)).frame(width: 174, height: 59).shadow(color: .black.opacity(0.3), radius: 9, y: 7)
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(Color(red: 0.65, green: 0.85, blue: 1))
                    }
                }.frame(height: 147)
                VStack(spacing: 10) {
                    Text(mode.title).font(.system(size: 21, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(height: 38)
                }
            }
            .padding(28).frame(width: 322, height: 302)
            .background(Color(red: 0.105, green: 0.115, blue: 0.135), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityLabel(mode.title)
    }
}

struct ModeSettingsView: View {
    @EnvironmentObject private var settings: WorkspaceSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("编辑模式", "Editing mode")).font(.headline)
            Picker(L10n.text("模式", "Mode"), selection: Binding(get: { settings.mode ?? .rings }, set: { settings.mode = $0 })) {
                ForEach(EditorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            Text(L10n.text("切换模式会保留当前视频和两种效果。", "Switching modes keeps your video and both types of effects."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            RepositoryLink()
        }.padding(28).frame(width: 430).preferredColorScheme(.dark)
    }
}
