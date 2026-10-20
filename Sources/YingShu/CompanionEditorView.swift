import AppKit
import SwiftUI

private enum CompanionPalette {
    static let paper = Color(red: 0.967, green: 0.958, blue: 0.936)
    static let ink = Color(red: 0.15, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.46)
    static let coral = Color(red: 0.88, green: 0.32, blue: 0.25)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.83)
}

@MainActor struct CompanionEditorSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var draft: CompanionEditorDraft

    init(model: AppModel) {
        self.model = model
        _draft = StateObject(wrappedValue: CompanionEditorDraft(profile: model.companionProfile))
    }
    var body: some View {
        CompanionEditorContent(profile: $draft.profile, useAsDefault: $draft.useAsDefault, isPreparing: draft.isPreparing,
            error: draft.issue, cancel: cancel, complete: complete)
            .frame(width: 760, height: 660)
            .interactiveDismissDisabled()
            .onDisappear { draft.preparation?.cancel() }
    }
    private func cancel() {
        draft.preparation?.cancel()
        model.cancelCompanionEditing()
    }
    private func complete() {
        guard !draft.isPreparing else { return }
        let confirmed = draft.profile.normalized(), saveDefault = draft.useAsDefault
        draft.isPreparing = true; draft.issue = nil
        draft.preparation = Task { @MainActor in
            do {
                try await CompanionStickerRenderer.prepare(confirmed)
                try Task.checkCancellation()
                model.finishCompanionEditing(confirmed, useAsDefault: saveDefault)
            } catch is CancellationError {
                draft.isPreparing = false
            } catch {
                draft.isPreparing = false
                draft.issue = error.localizedDescription
            }
        }
    }
}

@MainActor private final class CompanionEditorDraft: ObservableObject {
    @Published var profile: CompanionProfile
    @Published var useAsDefault = true
    @Published var isPreparing = false
    @Published var issue: String?
    var preparation: Task<Void, Never>?
    init(profile: CompanionProfile) { self.profile = profile }
}

/// This content is shared by the real sheet and the visual verification fixture.
@MainActor struct CompanionEditorContent: View {
    @Binding var profile: CompanionProfile
    @Binding var useAsDefault: Bool
    var isPreparing = false
    var error: String? = nil
    var cancel: () -> Void
    var complete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    previewColumn.frame(width: 262)
                    choices.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 26).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            footer
        }
        .background(CompanionPalette.paper)
        .foregroundStyle(CompanionPalette.ink)
        .tint(CompanionPalette.coral)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.editor")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("捏一个自己的小人").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("选个喜欢的样子，再加一点你的特色。")
                    .font(.system(size: 12)).foregroundStyle(CompanionPalette.muted)
            }
            Spacer()
            Image(systemName: "sparkle").font(.system(size: 25, weight: .light))
                .foregroundStyle(CompanionPalette.coral.opacity(0.65)).padding(.top, 4).accessibilityHidden(true)
        }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 23)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [Color(red: 0.88, green: 0.91, blue: 0.83), Color(red: 0.96, green: 0.93, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Ellipse().fill(CompanionPalette.ink.opacity(0.09)).frame(width: 126, height: 15).blur(radius: 5).padding(.bottom, 25)
                CompanionThumbnail(profile: profile).frame(width: 222, height: 277).padding(.bottom, 8)
                Text("和你一起，把感想留在画面里")
                    .font(.system(size: 10)).foregroundStyle(CompanionPalette.ink.opacity(0.55)).padding(.bottom, 10)
            }.frame(height: 294).accessibilityLabel("\(profile.displayName)，当前造型预览")
            HStack {
                Text("叫它什么？").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("可选 · 12 字内").font(.system(size: 10)).foregroundStyle(CompanionPalette.muted)
            }
            TextField("我的小旅伴", text: Binding(get: { profile.name }, set: { profile.name = String($0.prefix(12)) }))
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(CompanionPalette.line.opacity(0.8)) }
                .accessibilityLabel("小人昵称，最多十二个字").accessibilityIdentifier("companion.name")
                .disabled(isPreparing)
            Text("造型会跟随本作品保存，\n预览、图片与视频使用同一个小人。")
                .font(.system(size: 10)).foregroundStyle(CompanionPalette.muted).lineSpacing(4)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 10) {
                Text("从一个灵感开始").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 7) {
                    ForEach(CompanionInspiration.all) { inspiration in
                        let selected = profile.visualKey == inspiration.profile.visualKey
                        Button {
                            let name = profile.name
                            profile = inspiration.profile
                            profile.name = name
                        } label: {
                            VStack(spacing: 4) {
                                CompanionThumbnail(profile: inspiration.profile).frame(height: 64)
                                Text(inspiration.name).font(.system(size: 9, weight: selected ? .semibold : .regular)).lineLimit(1)
                            }.frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(selected ? Color.white : Color.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))
                                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? CompanionPalette.coral : CompanionPalette.line.opacity(0.5), lineWidth: selected ? 1.5 : 1) }
                        }.buttonStyle(.plain).accessibilityLabel("灵感造型，\(inspiration.name)")
                            .accessibilityValue(selected ? "已选中" : "")
                            .accessibilityIdentifier("companion.inspiration.\(inspiration.id)")
                    }
                }
            }
            Rectangle().fill(CompanionPalette.line.opacity(0.7)).frame(height: 1)
            VStack(alignment: .leading, spacing: 15) {
                Text("再加一点自己的特色").font(.system(size: 12, weight: .semibold))
                optionRow("肤色") {
                    ForEach(CompanionSkinTone.allCases) { tone in
                        swatch(tone.color, label: tone.label, selected: profile.skinTone == tone, id: "skinTone.\(tone.rawValue)") { profile.skinTone = tone }
                    }
                }
                optionRow("发型") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(CompanionHairStyle.allCases) { style in
                            chip(style.label, selected: profile.hairStyle == style, id: "hairStyle.\(style.rawValue)") { profile.hairStyle = style }
                        }
                    }
                }
                optionRow("发色") {
                    ForEach(CompanionHairColor.allCases) { color in
                        swatch(color.color, label: color.label, selected: profile.hairColor == color, id: "hairColor.\(color.rawValue)") { profile.hairColor = color }
                    }
                    if hidesHair { Text("当前造型无露出的头发").font(.system(size: 9)).foregroundStyle(CompanionPalette.muted).fixedSize() }
                }.disabled(hidesHair).help(hidesHair ? "选择有头发的发型后可更改发色。" : "选择发色")
                optionRow("脸型") {
                    ForEach(CompanionFaceShape.allCases) { shape in
                        chip(shape.label, selected: profile.faceShape == shape, id: "faceShape.\(shape.rawValue)") { profile.faceShape = shape }
                    }
                }
                optionRow("衣色") {
                    ForEach(CompanionOutfitColor.allCases) { color in
                        swatch(color.color, label: color.label, selected: profile.outfitColor == color, id: "outfitColor.\(color.rawValue)") { profile.outfitColor = color }
                    }
                }
                optionRow("眼镜") {
                    ForEach(CompanionGlassesStyle.allCases) { style in
                        chip(style.label, selected: profile.glassesStyle == style, id: "glassesStyle.\(style.rawValue)") { profile.glassesStyle = style }
                    }
                }
            }
        }.disabled(isPreparing)
    }
    private var hidesHair: Bool { profile.hairStyle == .bucketHat || profile.hairStyle == .bald }
    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(CompanionPalette.muted).frame(width: 29, alignment: .leading)
            content()
        }
    }
    private func swatch(_ color: NSColor, label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(nsColor: color)).frame(width: 24, height: 24)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 1) }
                Circle().strokeBorder(selected ? CompanionPalette.coral : .clear, lineWidth: 1.5).frame(width: 31, height: 31)
            }.frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityValue(selected ? "已选中" : "")
            .accessibilityIdentifier("companion.\(id)")
    }
    private func chip(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.horizontal, 6).frame(height: 28)
                .background(selected ? Color.white : Color.white.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? CompanionPalette.coral : CompanionPalette.line.opacity(0.75), lineWidth: selected ? 1.5 : 1) }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(selected ? "已选中" : "")
            .accessibilityIdentifier("companion.\(id)")
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11))
                    .foregroundStyle(CompanionPalette.coral).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("companion.error")
            }
            HStack(spacing: 12) {
                Toggle("以后新作品也用这个小人", isOn: $useAsDefault)
                    .toggleStyle(.checkbox).font(.system(size: 11)).disabled(isPreparing)
                    .accessibilityIdentifier("companion.default")
                Spacer(minLength: 5)
                if isPreparing {
                    ProgressView().controlSize(.mini)
                    Text("准备你的旅伴…").font(.system(size: 10)).foregroundStyle(CompanionPalette.muted)
                        .accessibilityIdentifier("companion.preparing")
                }
                Button("取消", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("companion.cancel")
                Button("就用这个", action: complete).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isPreparing).accessibilityIdentifier("companion.complete")
            }
            Text("完成后，新口述使用小人气泡；已有其他样式保持原样。")
                .font(.system(size: 10)).foregroundStyle(CompanionPalette.muted)
        }.padding(.horizontal, 28).padding(.vertical, 16)
            .background(.white.opacity(0.48))
            .overlay(alignment: .top) { Rectangle().fill(CompanionPalette.line.opacity(0.6)).frame(height: 1) }
    }
}

@MainActor struct CompanionThumbnail: View {
    var profile: CompanionProfile
    var body: some View {
        if let image = CompanionStickerRenderer.previewImage(for: profile) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
        } else {
            Image(systemName: "person.fill").resizable().scaledToFit().padding(16).foregroundStyle(CompanionPalette.muted)
        }
    }
}

private struct CompanionInspiration: Identifiable {
    var id: String
    var name: String
    var profile: CompanionProfile
    static let all = [
        Self(id: "classic", name: "经典旅人", profile: .classic),
        Self(id: "mountain", name: "山间小憩", profile: CompanionProfile(skinTone: .peach, hairStyle: .short, faceShape: .oval, outfitColor: .sage, glassesStyle: .round)),
        Self(id: "ocean", name: "海边的风", profile: CompanionProfile(skinTone: .honey, hairStyle: .bob, hairColor: .chestnut, outfitColor: .ocean)),
        Self(id: "city", name: "城市漫游", profile: CompanionProfile(skinTone: .cocoa, hairStyle: .curls, faceShape: .softSquare, outfitColor: .lavender, glassesStyle: .square))
    ]
}
