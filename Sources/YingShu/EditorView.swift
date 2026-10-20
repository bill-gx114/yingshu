import AppKit
import AVFoundation
import QuartzCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum StudioPalette {
    static let paper = Color(red: 0.967, green: 0.958, blue: 0.936)
    static let panel = Color(red: 0.992, green: 0.988, blue: 0.976)
    static let ink = Color(red: 0.15, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.46)
    static let coral = Color(red: 0.88, green: 0.32, blue: 0.25)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.83)
    static let cinema = Color(red: 0.105, green: 0.12, blue: 0.115)
}

struct EditorView: View {
    @ObservedObject var model: AppModel
    @StateObject private var drop = DropFeedback()
    @StateObject private var presentation = EditorPresentation()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(StudioPalette.line)
            HStack(spacing: 0) {
                MediaSidebar(model: model).frame(width: 198)
                Divider().overlay(StudioPalette.line)
                mainWorkspace
                Divider().overlay(StudioPalette.line)
                InspectorPanel(model: model).frame(width: 280)
            }
            bottomStatus
        }
        .background(StudioPalette.paper)
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.coral)
        .overlay {
            if drop.targeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(StudioPalette.coral, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(5).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $drop.targeted, perform: importDrop)
        .onChange(of: model.isExporting) { wasExporting, exporting in
            if exporting { presentation.showExportSuccess = false }
            else if wasExporting && model.exportProgress == 1 && model.lastExportURL != nil { presentation.showExportSuccess = true }
        }
        .onChange(of: model.lastExportURL) { _, url in if url == nil { presentation.showExportSuccess = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMissingProjectAssets()
        }
        .overlay(alignment: .topTrailing) {
            if presentation.showExportSuccess, let url = model.lastExportURL {
                ExportSuccessCard(url: url, kindLabel: model.exportKindLabel, reveal: model.revealExport, dismiss: { presentation.showExportSuccess = false })
                    .padding(.top, 76).padding(.trailing, 18)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }.accessibilityIdentifier("error.dismiss")
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { model.editingCaptionID != nil }, set: { presented in
            if !presented && model.editingCaptionID != nil { model.cancelCaptionEditing() }
        })) {
            CaptionEditSheet(model: model).interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.isShowingMissingAssets) {
            MissingAssetsContent(assets: model.missingProjectAssets, isRelinking: model.isRelinkingAssets, issue: model.assetRelinkIssue,
                locate: model.locateMissingAsset, refresh: model.refreshMissingProjectAssets,
                done: { model.isShowingMissingAssets = false })
                .interactiveDismissDisabled(model.isRelinkingAssets)
        }
        .sheet(isPresented: $model.isShowingCompanionEditor) {
            CompanionEditorSheet(model: model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 15) {
            HStack(spacing: 9) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(StudioPalette.coral)
                Text("映述").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("边看边说成片").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            }
            .padding(.leading, 9)
            Rectangle().fill(StudioPalette.line).frame(width: 1, height: 24)
            HStack(spacing: 7) {
                TextField("给短片取个名字", text: Binding(get: { model.title }, set: model.setProjectTitle))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .disabled(!model.canEditStructure)
                    .accessibilityLabel("短片名称").accessibilityIdentifier("project.title")
                if model.hasUnsavedProjectChanges {
                    Circle().fill(StudioPalette.coral).frame(width: 5, height: 5)
                        .accessibilityLabel("项目有未保存的修改").accessibilityIdentifier("project.unsaved")
                }
            }
            .frame(minWidth: 110, maxWidth: 230).help("\(model.title)\n\(projectSaveHelp)")
            Spacer(minLength: 8)
            Button { model.newProject() } label: { Label("新建", systemImage: "plus") }
                .help("新建手记 ⌘N").accessibilityIdentifier("project.new").disabled(!model.canEditStructure)
            Button { model.openProject() } label: { Label("打开", systemImage: "folder") }
                .help("打开项目 ⌘O").accessibilityIdentifier("project.open").disabled(!model.canEditStructure)
            Button { model.saveProject() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .help(projectSaveHelp).accessibilityIdentifier("project.save").disabled(!model.canEditStructure)
            HStack(spacing: 0) {
                Button(action: model.exportVideo) {
                    Label("导出短片", systemImage: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 8).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityIdentifier("project.export")
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 16)
                Menu {
                    Button("导出短片 MP4", action: model.exportVideo).accessibilityIdentifier("project.export.video")
                    Button("导出带字图片…", action: model.exportCaptionImages)
                        .disabled(!model.captions.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
                        .accessibilityIdentifier("project.export.images")
                    if !model.captions.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        Text("先为画面加一句文字，即可导出 PNG。")
                    }
                } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.white) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundColor(.white).frame(width: 26, height: 32)
                .accessibilityLabel("选择导出格式").accessibilityIdentifier("project.export.formats")
                .help("可导出 MP4 短片，或带字画面的 PNG 图片。")
            }
            .background(StudioPalette.ink, in: RoundedRectangle(cornerRadius: 8)).disabled(model.clips.isEmpty || !model.canEditStructure)
            .opacity(model.clips.isEmpty || !model.canEditStructure ? 0.45 : 1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).frame(height: 65)
        .background(StudioPalette.panel)
        .disabled(model.isExporting)
    }

    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            if !model.missingProjectAssets.isEmpty {
                MissingAssetsBanner(count: model.missingProjectAssets.count, canManage: model.canEditStructure) {
                    model.pause()
                    model.refreshMissingProjectAssets()
                    model.isShowingMissingAssets = true
                }
            }
            if model.clips.isEmpty {
                EmptyStudioView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                previewHeader
                MoviePreview(model: model).padding(.horizontal, 24).padding(.bottom, 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TransportPanel(model: model).padding(.horizontal, 24).padding(.bottom, 18)
                Divider().overlay(StudioPalette.line)
                TimelineStrip(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewHeader: some View {
        HStack {
            Label("故事预览", systemImage: "play.rectangle").font(.system(size: 12, weight: .semibold))
            if model.currentClip?.livePhotoStillURL != nil { LivePhotoBadge() }
            if !model.visibleCaptions.isEmpty {
                Text("点击文字修改").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            }
            Spacer()
            Label("原声静音", systemImage: "speaker.slash").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            Picker("画面比例", selection: Binding(get: { model.format }, set: model.setVideoFormat)) {
                ForEach(VideoFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 122).disabled(!model.canEditStructure)
            .accessibilityIdentifier("preview.format")
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 13)
    }

    private var bottomStatus: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if model.isBusy || model.isTranscribing || model.isAutoEditing || model.isOrdering || model.isPreparingCaptionEdit { ProgressView().controlSize(.mini) }
                else { Circle().fill(model.speech.isRecording ? StudioPalette.coral : Color(red: 0.39, green: 0.54, blue: 0.41)).frame(width: 5, height: 5) }
                Text(model.status).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .help(model.status)
                    .accessibilityIdentifier("status.message")
                Spacer()
                if model.lastExportURL != nil {
                    Button("查看导出", action: model.revealExport).font(.system(size: 11)).buttonStyle(.borderless)
                        .accessibilityLabel("在 Finder 中查看导出结果").accessibilityIdentifier("export.reveal.status")
                }
                RecoverySaveStatus(state: model.recoverySaveState, label: model.recoverySaveLabel,
                    detail: model.recoverySaveDetail, canRetry: model.canEditStructure, retry: model.retryRecoverySave)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 18).frame(height: 30)
            if model.hasRecoverySaveFailure { RecoverySaveFailureDetail(detail: model.recoverySaveDetail) }
        }
        .background(StudioPalette.panel)
        .overlay(alignment: .top) { Rectangle().fill(StudioPalette.line).frame(height: 1) }
    }

    private var projectSaveHelp: String {
        if let url = model.projectURL {
            return "项目文件：\(url.path)\n⌘S 保存到此文件；⇧⌘S 另存为。\(model.hasUnsavedProjectChanges ? "当前有未保存的修改。" : "")"
        }
        return "⌘S 保存项目文件，以便重新打开或携带。项目引用原始素材，请一并保留。"
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canEditStructure else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let url = value as? URL { continuation.resume(returning: url) }
                        else if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url { urls.append(url) }
            }
            await model.importURLs(urls)
        }
        return true
    }
}

private final class DropFeedback: ObservableObject { @Published var targeted = false }
private final class EditorPresentation: ObservableObject { @Published var showExportSuccess = false }

struct RecoverySaveStatus: View {
    var state: RecoverySaveState
    var label: String
    var detail: String
    var canRetry: Bool
    var retry: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if state == .pending { ProgressView().controlSize(.mini).accessibilityLabel("正在自动保留项目") }
            else { Image(systemName: symbol).accessibilityHidden(true) }
            Text(label).lineLimit(1).accessibilityValue(detail).accessibilityIdentifier("recovery.message")
            if case .failed = state {
                Button("重试", action: retry).buttonStyle(.borderless).disabled(!canRetry)
                    .help(canRetry ? detail : "当前操作完成后可重试。\n\(detail)")
                    .accessibilityLabel("重新尝试自动保留项目").accessibilityIdentifier("recovery.retry")
            }
        }
        .font(.system(size: 10)).foregroundStyle(isFailure ? StudioPalette.coral : StudioPalette.muted)
        .help(detail).accessibilityElement(children: .contain).accessibilityIdentifier("recovery.state")
    }
    private var isFailure: Bool { if case .failed = state { return true }; return false }
    private var symbol: String {
        switch state {
        case .idle: return "clock"
        case .pending: return "arrow.triangle.2.circlepath"
        case .saved: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .disabled: return "pause.circle"
        }
    }
}

struct RecoverySaveFailureDetail: View {
    var detail: String
    var body: some View {
        ScrollView {
            Text(detail).font(.system(size: 11)).lineSpacing(3).foregroundStyle(StudioPalette.coral)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).accessibilityIdentifier("recovery.detail")
        }
        .scrollIndicators(.visible).frame(height: 54).padding(.horizontal, 18).padding(.bottom, 8)
    }
}

struct MissingAssetsBanner: View {
    var count: Int
    var canManage: Bool
    var manage: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(StudioPalette.coral).accessibilityHidden(true)
            Text("\(count) 项素材需要重新关联").font(.system(size: 11, weight: .medium)).lineLimit(2)
            Spacer(minLength: 4)
            Button("选择新位置…", action: manage).buttonStyle(.borderless).font(.system(size: 11)).disabled(!canManage)
                .accessibilityIdentifier("assets.manage")
        }
        .padding(.horizontal, 17).padding(.vertical, 10)
        .background(StudioPalette.coral.opacity(0.055))
        .overlay(alignment: .bottom) { Rectangle().fill(StudioPalette.line).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("assets.banner")
    }
}

struct MissingAssetsContent: View {
    var assets: [MissingProjectAsset]
    var isRelinking: Bool
    var issue: String? = nil
    var locate: (MissingProjectAsset) -> Void
    var refresh: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重新关联素材").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("素材移动或改名后，选择新位置即可继续；感想和剪辑设置会保留。")
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
            if assets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: isRelinking ? "doc.text.magnifyingglass" : "checkmark.circle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(isRelinking ? StudioPalette.muted : Color(red: 0.35, green: 0.53, blue: 0.39))
                    Text(isRelinking ? "正在确认素材位置…" : "素材位置已确认").font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier(isRelinking ? "assets.validating" : "assets.complete")
            } else {
                Text("待关联 \(assets.count) 项").font(.system(size: 11, weight: .medium)).accessibilityIdentifier("assets.count")
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            if let issue {
                                Text(issue).font(.system(size: 11)).foregroundStyle(StudioPalette.coral)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled).padding(10)
                                    .background(StudioPalette.coral.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("assets.issue").id("asset-issue")
                            }
                            LazyVStack(spacing: 9) { ForEach(assets) { asset in assetRow(asset) } }
                        }.padding(.trailing, 2)
                    }
                    .scrollIndicators(.visible).frame(maxHeight: .infinity).accessibilityIdentifier("assets.list")
                    .onChange(of: issue) { _, issue in if issue != nil { scroll.scrollTo("asset-issue", anchor: .top) } }
                }
            }
            HStack(spacing: 9) {
                if isRelinking {
                    ProgressView().controlSize(.small)
                    Text("正在核验所选素材…").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                        .accessibilityIdentifier("assets.progress")
                } else if !assets.isEmpty {
                    Text("其余素材可稍后继续关联。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                }
                Spacer(minLength: 4)
                Button("重新检查", action: refresh).disabled(isRelinking).accessibilityIdentifier("assets.refresh")
                Button("完成", action: done).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(isRelinking)
                    .accessibilityIdentifier("assets.done")
            }
        }
        .padding(24).frame(width: 640, height: 490).background(StudioPalette.paper).foregroundStyle(StudioPalette.ink).tint(StudioPalette.coral)
        .onExitCommand { if !isRelinking { done() } }
        .accessibilityIdentifier("assets.sheet")
    }

    private func assetRow(_ asset: MissingProjectAsset) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(asset.label).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true).help(asset.label)
                    Text(asset.kind.rawValue).font(.system(size: 9)).foregroundStyle(StudioPalette.muted)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(StudioPalette.paper, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
                }
                Text(asset.url.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).help(asset.url.path)
                    .accessibilityIdentifier("assets.path.\(asset.id)")
                if asset.kind == .livePhoto {
                    Text("请选择同一张实况照片的照片与 MOV 文件。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("重新选择…") { locate(asset) }.disabled(isRelinking)
                .fixedSize().help(isRelinking ? "正在核验当前选择，请稍候。" : "选择此素材的新位置；保留现有感想和剪辑。")
                .accessibilityLabel("为\(asset.label)重新选择\(asset.kind.rawValue)")
                .accessibilityIdentifier("assets.locate.\(asset.id)")
        }
        .padding(12).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(StudioPalette.line) }
    }
}

struct CaptionEditSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        CaptionEditorContent(draft: $model.captionEditDraft,
            state: CaptionCleanupPresentationState(isCleaning: model.isCleaningCaption,
                suggestion: model.captionCleanupSuggestion, issue: model.captionCleanupIssue,
                originalText: model.captionCleanupOriginalText, availability: model.captionCleanupAvailabilityMessage,
                canUseAI: model.canUseCaptionAI, editorIssue: model.captionEditIssue),
            actions: CaptionCleanupActions(request: model.requestCaptionCleanup, cancelRequest: model.cancelCaptionCleanup,
                adopt: model.adoptCaptionCleanupSuggestion, restore: model.restoreCaptionCleanupOriginal,
                basicClean: model.basicCleanCaptionDraft, cancel: model.cancelCaptionEditing, save: model.saveCaptionEditing))
    }
}

struct CaptionCleanupPresentationState {
    var isCleaning = false
    var suggestion: String?
    var issue: String?
    var originalText: String?
    var availability = ""
    var canUseAI = false
    var editorIssue: String?
}

struct CaptionCleanupActions {
    var request: () -> Void = {}
    var cancelRequest: () -> Void = {}
    var adopt: () -> Void = {}
    var restore: () -> Void = {}
    var basicClean: () -> Void = {}
    var cancel: () -> Void = {}
    var save: () -> Void = {}
}

/// All cleanup results remain separate from the editable draft until explicitly adopted.
struct CaptionEditorContent: View {
    @Binding var draft: String
    @FocusState private var isDraftFocused: Bool
    var state: CaptionCleanupPresentationState
    var actions: CaptionCleanupActions
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改这句话").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("正常口述会自动整理，这里用于再次修改。\n建议需先采用，点击完成后再更新画面。")
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    cleanupControls
                    if let original = state.originalText {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("整理前").font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Button("恢复整理前", action: actions.restore).font(.system(size: 10)).buttonStyle(.borderless)
                                    .disabled(state.isCleaning || original == draft).opacity(state.isCleaning || original == draft ? 0.4 : 1)
                                    .accessibilityIdentifier("captionCleanup.restore")
                            }
                            ScrollView { Text(original).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(height: 66).padding(9).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                                .accessibilityIdentifier("captionCleanup.original")
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("画面文字").font(.system(size: 11, weight: .semibold))
                        TextEditor(text: $draft).font(.system(size: 14)).lineSpacing(5)
                            .focused($isDraftFocused)
                            .scrollContentBackground(.hidden).padding(9).frame(height: 128)
                            .background(.white, in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(StudioPalette.line) }
                            .accessibilityLabel("画面文字草稿").accessibilityIdentifier("captionEditor.text")
                    }
                    if let suggestion = state.suggestion { suggestionCard(suggestion) }
                }.padding(.trailing, 2)
            }.scrollIndicators(.visible)
            if let issue = state.editorIssue {
                Text(issue).font(.system(size: 11)).foregroundStyle(StudioPalette.coral).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("captionEditor.issue")
            }
            HStack {
                Text("保留时间与样式，可撤销修改。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                Spacer(minLength: 8)
                Button("取消", action: actions.cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("captionEditor.cancel")
                Button("完成", action: actions.save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(StudioPalette.coral).disabled(state.isCleaning)
                    .accessibilityIdentifier("captionEditor.save")
            }
        }
        .padding(24).frame(width: 520, height: 620).background(StudioPalette.paper).foregroundStyle(StudioPalette.ink).tint(StudioPalette.coral)
        .task { isDraftFocused = true }
        .accessibilityIdentifier("captionEditor.sheet")
    }
    private var cleanupControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Button(action: actions.basicClean) { Label("基础整理", systemImage: "text.badge.checkmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.bordered).disabled(state.isCleaning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("处理空白与标点，不猜测人名、地名或日期。")
                    .accessibilityIdentifier("captionCleanup.basic")
                Button(action: actions.request) { Label("AI 整理", systemImage: "sparkles").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(!state.canUseAI || state.isCleaning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(!state.canUseAI || state.isCleaning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                    .help(state.availability).accessibilityIdentifier("captionCleanup.request")
                Spacer(minLength: 0)
            }
            Text("基础整理仅处理空白与标点，不需要 AI 模型。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            if !state.availability.isEmpty {
                Text(state.availability).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).help(state.availability).accessibilityIdentifier("captionCleanup.availability")
            }
            if state.isCleaning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理这句…").font(.system(size: 11))
                    Spacer()
                    Button("取消整理", action: actions.cancelRequest).font(.system(size: 11)).buttonStyle(.borderless)
                        .accessibilityIdentifier("captionCleanup.cancel")
                }.accessibilityIdentifier("captionCleanup.progress")
            }
            if let issue = state.issue, issue != state.availability {
                Text(issue).font(.system(size: 11)).foregroundStyle(StudioPalette.coral).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("captionCleanup.issue")
            }
        }
    }
    private func suggestionCard(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 建议", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("采用建议", action: actions.adopt).font(.system(size: 11, weight: .medium)).buttonStyle(.bordered)
                    .disabled(state.isCleaning).accessibilityIdentifier("captionCleanup.adopt")
            }
            ScrollView { Text(suggestion).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 94).accessibilityIdentifier("captionCleanup.suggestion")
            Text("请核对人名、地名与时间。采用后仍可继续修改草稿。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
        }.padding(12).background(StudioPalette.coral.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SpeechSettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var deepSeekSettings = DeepSeekSettings.shared
    @StateObject private var draft = SpeechSettingsDraft()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SpeechSettingsContent(mode: Binding(get: { model.speechMode }, set: model.updateSpeechMode),
            vocabulary: $draft.vocabulary,
            state: SpeechSettingsPresentationState(engineSummary: model.speechEngineSummary,
                enhancedAvailability: model.enhancedSpeechAvailability, downloadProgress: model.enhancedSpeechDownloadProgress,
                isPreparing: model.isPreparingEnhancedSpeechModel, cleanupAvailability: model.captionCleanupAvailabilityMessage,
                localAIReady: model.localAIReady, localAIStatus: model.localAIStatusMessage),
            deepSeek: DeepSeekSettingsPresentationState(hasAPIKey: deepSeekSettings.hasAPIKey,
                isEnabled: deepSeekSettings.isEnabled, isTesting: draft.isTesting || deepSeekSettings.isTesting,
                feedback: draft.deepSeekFeedback, feedbackIsError: draft.deepSeekFeedbackIsError),
            deepSeekKeyDraft: Binding(get: { draft.apiKey }, set: { draft.apiKey = $0; draft.deepSeekFeedback = nil }),
            deepSeekActions: DeepSeekSettingsActions(setEnabled: { deepSeekSettings.isEnabled = $0 },
                saveKey: saveDeepSeekKey, removeKey: removeDeepSeekKey,
                testConnection: testDeepSeekConnection, cancelTest: draft.cancelTest),
            prepare: model.prepareEnhancedSpeechModel, cancelPreparation: model.cancelEnhancedSpeechPreparation,
            cancel: {
                if model.isPreparingEnhancedSpeechModel { model.cancelEnhancedSpeechPreparation() }
                dismiss()
            }, complete: { model.updateSpeechVocabulary(draft.vocabulary); dismiss() })
            .onAppear { model.pause(); model.isShowingSpeechSettings = true; draft.vocabulary = model.speechVocabularyText }
            .onDisappear { draft.cancelTest(); draft.apiKey = ""; model.isShowingSpeechSettings = false }
    }
    private func saveDeepSeekKey() {
        guard !draft.isTesting, !deepSeekSettings.isTesting else { return }
        do {
            try deepSeekSettings.saveAPIKey(draft.apiKey)
            draft.apiKey = ""
            draft.setFeedback("API Key 已保存到本机钥匙串。", isError: false)
        } catch {
            draft.setFeedback(deepSeekSettings.status, isError: true)
        }
    }
    private func removeDeepSeekKey() {
        guard !draft.isTesting, !deepSeekSettings.isTesting else { return }
        do {
            try deepSeekSettings.removeAPIKey()
            draft.apiKey = ""
            draft.setFeedback("API Key 已移除，文字整理已恢复本机处理。", isError: false)
        } catch {
            draft.setFeedback(deepSeekSettings.status, isError: true)
        }
    }
    private func testDeepSeekConnection() {
        guard deepSeekSettings.hasAPIKey, !draft.isTesting, !deepSeekSettings.isTesting else { return }
        let requestID = UUID()
        draft.testRequestID = requestID
        draft.isTesting = true
        draft.deepSeekFeedback = nil
        draft.testTask = Task { @MainActor in
            defer {
                if draft.testRequestID == requestID {
                    draft.isTesting = false
                    draft.testTask = nil
                    draft.testRequestID = nil
                }
            }
            await deepSeekSettings.testConnection()
            guard !Task.isCancelled, draft.testRequestID == requestID else { return }
            draft.setFeedback(deepSeekSettings.status, isError: deepSeekSettings.connectionTestSucceeded != true)
        }
    }
}

@MainActor
private final class SpeechSettingsDraft: ObservableObject {
    @Published var vocabulary = ""
    @Published var apiKey = ""
    @Published var isTesting = false
    @Published var deepSeekFeedback: String?
    @Published var deepSeekFeedbackIsError = false
    var testTask: Task<Void, Never>?
    var testRequestID: UUID?

    func setFeedback(_ message: String, isError: Bool) {
        deepSeekFeedback = message
        deepSeekFeedbackIsError = isError
    }
    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testRequestID = nil
        isTesting = false
    }
}

struct SpeechSettingsPresentationState {
    var engineSummary: String
    var enhancedAvailability: EnhancedSpeechModelAvailability
    var downloadProgress: Double?
    var isPreparing: Bool
    var cleanupAvailability: String
    var localAIReady = false
    var localAIStatus = ""
}

struct DeepSeekSettingsPresentationState {
    var hasAPIKey = false
    var isEnabled = false
    var isTesting = false
    var feedback: String?
    var feedbackIsError = false
}

struct DeepSeekSettingsActions {
    var setEnabled: (Bool) -> Void = { _ in }
    var saveKey: () -> Void = {}
    var removeKey: () -> Void = {}
    var testConnection: () -> Void = {}
    var cancelTest: () -> Void = {}
}

struct SpeechSettingsContent: View {
    @Binding var mode: SpeechRecognitionMode
    @Binding var vocabulary: String
    var state: SpeechSettingsPresentationState
    var deepSeek = DeepSeekSettingsPresentationState()
    var deepSeekKeyDraft: Binding<String> = .constant("")
    var deepSeekActions = DeepSeekSettingsActions()
    var prepare: () -> Void
    var cancelPreparation: () -> Void
    var cancel: () -> Void = {}
    var complete: () -> Void
    private var isPreparing: Bool { state.isPreparing || state.enhancedAvailability.isDownloading }
    private var hasPendingDeepSeekKey: Bool { !deepSeekKeyDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var progress: Double? {
        guard let value = state.downloadProgress, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("语音与整理设置").font(.system(size: 19, weight: .semibold, design: .rounded))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(state.engineSummary).font(.system(size: 12, weight: .medium)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.engine")
                    recognitionMode
                    if mode == .localAI { localAIModel }
                    else if mode == .localFirst { enhancedModel }
                    deepSeekConfiguration
                    vocabularyEditor
                    VStack(alignment: .leading, spacing: 7) {
                        Text("文字整理").font(.system(size: 12, weight: .semibold))
                        Text("基础整理可处理空白与标点，不需要 AI 模型。").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                        Text(state.cleanupAvailability).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.cleanupAvailability")
                    }
                }.padding(.trailing, 3)
            }.scrollIndicators(.visible)
            HStack {
                Text(isPreparing ? "先完成或取消模型准备，再保存词表。" : "词表点击完成后保存，用于下次口述。")
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("speechSettings.cancel")
                Button("完成", action: complete).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(isPreparing)
                    .accessibilityIdentifier("speechSettings.done")
            }
        }.padding(24).frame(width: 540, height: 640).background(StudioPalette.paper).foregroundStyle(StudioPalette.ink).tint(StudioPalette.coral)
            .accessibilityIdentifier("speechSettings.sheet")
    }
    private var recognitionMode: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("识别方式").font(.system(size: 12, weight: .semibold))
            Picker("识别方式", selection: $mode) {
                Text("AI 识别与整理").tag(SpeechRecognitionMode.localAI)
                Text("系统本机").tag(SpeechRecognitionMode.localFirst)
                Text("Apple 系统服务").tag(SpeechRecognitionMode.systemService)
            }.pickerStyle(.radioGroup).labelsHidden().disabled(isPreparing).accessibilityIdentifier("speechSettings.mode")
            Text(modeExplanation)
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("speechSettings.privacy")
        }
    }
    private var modeExplanation: String {
        switch mode {
        case .localAI:
            return deepSeek.isEnabled
                ? "语音在本机识别，识别后的本句文字交给 DeepSeek 整理。首次加载状态会在口述区显示。"
                : "在本机识别语音并整理表达，音频和文字不外发，无需 API Key。首次加载状态会在口述区显示。"
        case .localFirst: return "使用 Apple 本机语音识别；本机不可用时会提示，不自动改用联网识别。"
        case .systemService: return "允许 Apple 系统决定使用本机或联网识别，可能将语音发送给 Apple 处理。"
        }
    }
    private var deepSeekConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DeepSeek 整理文字", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(deepSeek.hasAPIKey ? "Key 已保存" : "可选")
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    .accessibilityIdentifier("speechSettings.deepSeekKeyStatus")
            }
            Toggle("使用 DeepSeek 整理文字", isOn: Binding(get: { deepSeek.isEnabled }, set: deepSeekActions.setEnabled))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                .disabled(!deepSeek.hasAPIKey || isPreparing || deepSeek.isTesting)
                .accessibilityIdentifier("speechSettings.deepSeekEnabled")
            Text(mode == .systemService
                ? "启用后仅发送本句文字与提示词到 DeepSeek，可能产生 API 费用；照片、视频与录音不上传到 DeepSeek。Apple 系统服务仍可能联网处理语音。"
                : "语音在本机识别；启用后仅发送本句文字与提示词到 DeepSeek，可能产生 API 费用；照片、视频与录音不上传到 DeepSeek。")
                .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.deepSeekPrivacy")
            Text("AI 识别模式下，说完自动整理；系统识别模式可在感想卡中整理。")
                .font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(deepSeek.hasAPIKey ? "输入新 API Key 以替换" : "输入 DeepSeek API Key", text: deepSeekKeyDraft)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .disabled(isPreparing || deepSeek.isTesting)
                .accessibilityLabel("DeepSeek API Key")
                .accessibilityIdentifier("speechSettings.deepSeekAPIKey")
            HStack(spacing: 9) {
                Button(deepSeek.hasAPIKey ? "替换 Key" : "保存 Key", action: deepSeekActions.saveKey)
                    .disabled(!hasPendingDeepSeekKey || isPreparing || deepSeek.isTesting)
                    .accessibilityIdentifier("speechSettings.deepSeekSave")
                if deepSeek.isTesting {
                    ProgressView().controlSize(.mini)
                    Text("测试中…").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    Button("取消测试", action: deepSeekActions.cancelTest)
                        .accessibilityIdentifier("speechSettings.deepSeekCancelTest")
                } else {
                    Button("测试连接", action: deepSeekActions.testConnection)
                        .disabled(!deepSeek.hasAPIKey || hasPendingDeepSeekKey || isPreparing)
                        .help("使用已保存在本机钥匙串的 API Key，用固定示例文字测试连接。")
                        .accessibilityIdentifier("speechSettings.deepSeekTest")
                }
                Spacer(minLength: 0)
                Button("移除 Key", action: deepSeekActions.removeKey)
                    .disabled(!deepSeek.hasAPIKey || isPreparing || deepSeek.isTesting)
                    .accessibilityIdentifier("speechSettings.deepSeekRemove")
            }.font(.system(size: 10)).buttonStyle(.bordered)
            if let feedback = deepSeek.feedback {
                Text(feedback).font(.system(size: 10))
                    .foregroundStyle(deepSeek.feedbackIsError ? StudioPalette.coral : StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.deepSeekFeedback")
            } else {
                Text(deepSeek.isTesting ? "用固定示例文字测试，不使用你的口述。"
                    : hasPendingDeepSeekKey ? "先保存输入的 Key，再用新 Key 测试连接。"
                    : "Key 仅存本机钥匙串；保存后再开启上方开关。")
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    .accessibilityIdentifier("speechSettings.deepSeekStorage")
            }
        }.padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(StudioPalette.line) }
            .accessibilityIdentifier("speechSettings.deepSeekConfiguration")
    }
    private var localAIModel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("本机 AI 运行环境").font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.localAIReady {
                    Label("已准备", systemImage: "checkmark.circle.fill").font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.35, green: 0.53, blue: 0.39)).accessibilityIdentifier("speechSettings.localAIReady")
                }
            }
            Text(state.localAIStatus).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.localAIStatus")
            if !state.localAIReady {
                Text("首次使用：先双击下载包里的“准备本地AI.command”。准备完成后重启映述，再选择上方的“AI识别与整理”。无需 API Key。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Button("查看本地 AI 准备步骤") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("本地AI说明.md") { NSWorkspace.shared.open(url) }
                }.font(.system(size: 11)).buttonStyle(.borderless)
                    .accessibilityIdentifier("speechSettings.localAIPrepareHelp")
            }
        }
    }
    private var enhancedModel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Apple 本机识别模型").font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.enhancedAvailability == .installed {
                    Label("系统模型已就绪", systemImage: "checkmark.circle.fill").font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.35, green: 0.53, blue: 0.39)).accessibilityIdentifier("speechSettings.modelReady")
                }
            }
            Text(state.enhancedAvailability.message).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speechSettings.modelAvailability")
            if isPreparing {
                if let progress {
                    HStack {
                        ProgressView(value: progress).tint(StudioPalette.coral).accessibilityIdentifier("speechSettings.modelProgress")
                        Text("\(Int(progress * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("等待系统提供下载进度…").font(.system(size: 10)).foregroundStyle(StudioPalette.muted) }
                        .accessibilityIdentifier("speechSettings.modelProgressUnknown")
                }
                Button("取消准备", action: cancelPreparation).font(.system(size: 11)).buttonStyle(.borderless)
                    .accessibilityIdentifier("speechSettings.cancelModel")
            } else if state.enhancedAvailability.canPrepare {
                Button("准备增强中文模型", action: prepare).font(.system(size: 11)).buttonStyle(.bordered)
                    .accessibilityIdentifier("speechSettings.prepareModel")
                Text("由 Apple 下载识别模型；准备好后在本机使用。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            }
        }
    }
    private var vocabularyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("口述词表").font(.system(size: 12, weight: .semibold))
            Text("写下地点、人名等短词，用逗号或换行分隔，最多 100 个。").font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
            TextEditor(text: $vocabulary).font(.system(size: 13)).lineSpacing(4)
                .scrollContentBackground(.hidden).padding(8).frame(height: 108).background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.line) }
                .accessibilityLabel("口述词表").accessibilityIdentifier("speechSettings.vocabulary")
        }
    }
}

private final class PhotoPickerSelection: ObservableObject { @Published var items: [PhotosPickerItem] = [] }

private struct PhotoLibraryImportButton: View {
    @ObservedObject var model: AppModel
    var identifier: String
    @StateObject private var selection = PhotoPickerSelection()
    var body: some View {
        PhotosPicker(selection: $selection.items, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current) {
            Label("从相册选择", systemImage: "photo.on.rectangle")
                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(.white).background(StudioPalette.coral, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(!model.canEditStructure).opacity(model.canEditStructure ? 1 : 0.5)
        .help("在系统相册中选择照片、视频或实况照片。")
        .accessibilityLabel("从系统相册选择素材").accessibilityIdentifier(identifier)
        .onChange(of: selection.items) { _, items in
            guard !items.isEmpty else { return }
            model.importFromPhotoLibrary(items: items)
            selection.items = []
        }
    }
}

private struct ExportSuccessCard: View {
    let url: URL
    let kindLabel: String
    let reveal: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.35, green: 0.53, blue: 0.39))
                Text("\(kindLabel)已保存").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(StudioPalette.muted)
                    .accessibilityLabel("关闭保存提示").accessibilityIdentifier("export.success.dismiss")
            }
            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(url) } label: { Label(isFolder ? "打开图片文件夹" : "播放短片", systemImage: isFolder ? "folder" : "play.fill") }
                    .accessibilityIdentifier(isFolder ? "export.success.openFolder" : "export.success.play")
                Button("查看文件", action: reveal).accessibilityIdentifier("export.success.reveal")
            }.font(.system(size: 11)).buttonStyle(.borderless)
        }
        .padding(16).frame(width: 268).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioPalette.line) }
        .shadow(color: .black.opacity(0.13), radius: 20, y: 8)
        .accessibilityIdentifier("export.success")
    }
    private var isFolder: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

private struct MediaSidebar: View {
    @ObservedObject var model: AppModel
    @StateObject private var importPresentation = ImportSummaryPresentation()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("素材").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.clips.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioPalette.muted)
            }.padding(.top, 22).padding(.bottom, 15)
            PhotoLibraryImportButton(model: model, identifier: "media.photos").padding(.bottom, 8)
            Button(action: model.importMedia) {
                Label("从文件导入", systemImage: "folder").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.plain).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.line) }
            .disabled(!model.canEditStructure)
            .opacity(model.canEditStructure ? 1 : 0.5)
            .accessibilityIdentifier("media.import")
            .help("选择照片和视频，也可以把素材拖进窗口。")
            if model.isImportingPhotoLibrary { photoLibraryProgress.padding(.top, 10) }
            if let summary = model.importSummary { importSummary(summary).padding(.top, 10) }
            orderControls.padding(.top, 14).padding(.bottom, 14)
            if model.clips.isEmpty {
                Spacer()
                Image(systemName: "photo.stack").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(StudioPalette.muted.opacity(0.55)).frame(maxWidth: .infinity)
                Text("放进这一程的画面").font(.system(size: 11)).foregroundStyle(StudioPalette.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                            MediaRow(model: model, clip: clip, index: index)
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("media.list")
            }
            Text("请保留原始素材").font(.system(size: 10)).foregroundStyle(StudioPalette.muted).padding(.vertical, 18)
                .help("项目引用原始文件；移动或删除素材后，项目将无法读取。")
        }
        .padding(.horizontal, 15).background(StudioPalette.panel.opacity(0.55))
    }

    private var photoLibraryProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("相册导入中").font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
                Button("取消", action: model.cancelPhotoLibraryImport).font(.system(size: 10)).buttonStyle(.borderless)
                    .accessibilityIdentifier("import.photos.cancel")
            }
            Text(model.status).font(.system(size: 9)).foregroundStyle(StudioPalette.muted).lineLimit(2).help(model.status)
        }.accessibilityIdentifier("import.photos.progress")
    }

    private func importSummary(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 5) {
                Text(summary).font(.system(size: 10)).lineLimit(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .help(summary).accessibilityIdentifier("import.summary")
                Button(action: model.clearImportSummary) { Image(systemName: "xmark").font(.system(size: 8, weight: .medium)).frame(width: 16, height: 16) }
                    .buttonStyle(.plain).foregroundStyle(StudioPalette.muted)
                    .accessibilityLabel("清除导入提示").accessibilityIdentifier("import.clear")
            }
            if !model.importDetails.isEmpty {
                DisclosureGroup(isExpanded: $importPresentation.expanded) {
                    ScrollView {
                        Text(model.importDetails.joined(separator: "\n\n")).font(.system(size: 10)).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.top, 5)
                    }.frame(maxHeight: 120)
                } label: { Text("查看详情").font(.system(size: 10)) }
                    .accessibilityIdentifier("import.details")
            }
        }.padding(9).background(StudioPalette.coral.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: summary) { _, _ in importPresentation.expanded = false }
    }

    private var orderControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("素材顺序").font(.system(size: 10, weight: .medium)).foregroundStyle(StudioPalette.muted)
                Spacer()
                Button(action: model.reapplyOrder) { Image(systemName: "arrow.clockwise").font(.system(size: 10)).frame(width: 22, height: 20) }
                    .buttonStyle(.borderless).disabled(!model.canEditStructure || model.clips.isEmpty || model.orderMode == .manual)
                    .opacity(!model.canEditStructure || model.clips.isEmpty || model.orderMode == .manual ? 0.4 : 1)
                    .help("重新按所选方式整理素材顺序")
                    .accessibilityLabel("重新整理素材顺序").accessibilityIdentifier("order.reapply")
            }
            Picker("素材顺序", selection: Binding(get: { model.orderMode }, set: model.setOrderMode)) {
                ForEach([ClipOrderMode.chronological, .story, .filename, .imported, .manual], id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity).disabled(!model.canEditStructure)
            .accessibilityIdentifier("order.mode")
            if model.isOrdering {
                Text(model.orderSummary.isEmpty ? "正在整理素材顺序…" : model.orderSummary)
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help(model.orderSummary)
                    .accessibilityIdentifier("order.summary")
                ProgressView(value: orderProgress).tint(StudioPalette.coral)
                    .accessibilityLabel("素材排序进度").accessibilityIdentifier("order.progress")
                HStack {
                    Text("\(Int(orderProgress * 100))%")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Button("取消整理", action: model.cancelOrdering).font(.system(size: 10)).buttonStyle(.borderless)
                        .accessibilityIdentifier("order.cancel")
                }
            } else if !model.clips.isEmpty && !model.orderSummary.isEmpty {
                Text(model.orderSummary).font(.system(size: 9)).foregroundStyle(StudioPalette.muted).lineSpacing(2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help(model.orderSummary)
                    .accessibilityIdentifier("order.summary")
            }
        }
    }
    private var orderProgress: Double { model.orderProgress.isFinite ? max(0, min(1, model.orderProgress)) : 0 }
}

private final class ImportSummaryPresentation: ObservableObject { @Published var expanded = false }

private struct LivePhotoBadge: View {
    var compact = false
    var body: some View {
        Label("实况", systemImage: "livephoto")
            .font(.system(size: compact ? 8 : 10, weight: .medium)).foregroundStyle(StudioPalette.coral)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 3 : 5).padding(.vertical, 2)
            .background(StudioPalette.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("实况照片，播放动态画面")
    }
}

private struct MediaRow: View {
    @ObservedObject var model: AppModel
    let clip: MediaClip
    let index: Int
    private var selected: Bool { model.selectedClipID == clip.id }
    var body: some View {
        HStack(spacing: 3) {
            Button { model.selectClip(clip) } label: {
                HStack(spacing: 7) {
                    thumbnail.frame(width: 38, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(clip.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 3) {
                            Text(String(format: "%02d", index + 1))
                            Text("·")
                            if clip.livePhotoStillURL != nil { LivePhotoBadge(compact: true) }
                            else { Text(clip.kind == .image ? "照片" : "视频") }
                            Spacer(minLength: 0)
                            Text(String(format: "%.1fs", clip.duration))
                        }.font(.system(size: 8)).foregroundStyle(StudioPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("第 \(index + 1) 段，\(clip.name)，\(clip.livePhotoStillURL != nil ? "实况，" : "")\(String(format: "%.1f", clip.duration)) 秒")
            .accessibilityValue(selected ? "已选中" : "")
            .accessibilityIdentifier("media.clip.\(clip.id.uuidString)").help(clip.name)
            Button { model.removeClip(clip.id) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                    .frame(width: 23, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("从项目移除，原文件保留")
            .accessibilityLabel("移除素材，\(clip.name)").accessibilityIdentifier("media.remove.\(clip.id.uuidString)")
        }
        .padding(6).background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? StudioPalette.coral.opacity(0.8) : Color.clear) }
        .disabled(!model.canEditStructure)
        .contextMenu {
            Button("从项目移除", role: .destructive) { model.removeClip(clip.id) }
                .disabled(!model.canEditStructure).accessibilityIdentifier("media.removeMenu.\(clip.id.uuidString)")
            Divider()
            Text("原文件保留")
        }
    }
    @ViewBuilder private var thumbnail: some View {
        if let image = model.thumbnails[clip.id] { Image(nsImage: image).resizable().scaledToFill() }
        else { Rectangle().fill(StudioPalette.line).overlay { Image(systemName: clip.kind == .image ? "photo" : "video").foregroundStyle(StudioPalette.muted) } }
    }
}

private struct EmptyStudioView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            ZStack {
                RoundedRectangle(cornerRadius: 15).fill(Color(red: 0.80, green: 0.85, blue: 0.76)).frame(width: 180, height: 120).rotationEffect(.degrees(-9)).offset(x: -30, y: -8)
                RoundedRectangle(cornerRadius: 15).fill(StudioPalette.ink).frame(width: 180, height: 120).rotationEffect(.degrees(6)).offset(x: 22, y: 5)
                Image(systemName: "waveform").font(.system(size: 35, weight: .light)).foregroundStyle(Color(red: 0.89, green: 0.96, blue: 0.73)).offset(x: 22, y: 5)
                Text("那天的风，刚刚好。")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color(red: 1, green: 0.96, blue: 0.84), in: RoundedRectangle(cornerRadius: 8))
                    .rotationEffect(.degrees(-3)).offset(x: -9, y: 64)
            }.frame(height: 180)
            Text("导入一次出游，\n边看边说成片。").font(.system(size: 29, weight: .semibold, design: .rounded)).multilineTextAlignment(.center).lineSpacing(7).padding(.top, 13)
            Text("照片、视频自动串联。\n看到哪里，就说说当时的心情。")
                .font(.system(size: 13)).foregroundStyle(StudioPalette.muted).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 15)
            HStack(spacing: 13) {
                PhotoLibraryImportButton(model: model, identifier: "empty.photos").frame(width: 168)
                Button(action: model.importMedia) {
                    Label("从文件导入", systemImage: "folder").font(.system(size: 12, weight: .medium)).padding(.vertical, 12)
                }.buttonStyle(.plain).accessibilityIdentifier("empty.import")
                Button("先试一下", action: model.loadDemo).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                    .accessibilityLabel("使用示例素材").accessibilityIdentifier("empty.demo")
            }.padding(.top, 27).disabled(!model.canEditStructure)
            HStack(spacing: 24) {
                step("01", "导入素材")
                step("02", "按 R 说感想")
                step("03", "导出短片")
            }.padding(.top, 31)
            Spacer(minLength: 30)
            Text("声音转成文字，成片搭配轻音乐。")
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).padding(.bottom, 24)
        }.padding(20)
    }
    private func step(_ number: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(number).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(StudioPalette.coral)
            Text(label).font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
        }
    }
}

private struct MoviePreview: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size
            let width = min(available.width, available.height * model.format.aspect)
            let height = width / model.format.aspect
            ZStack {
                StudioPalette.cinema
                if let clip = model.currentClip {
                    ZStack {
                        Color.black
                        if clip.kind == .video { PlayerSurface(player: model.player).frame(width: max(0, width), height: max(0, height)) }
                        else { ImageSurface(url: clip.url).frame(width: max(0, width), height: max(0, height)) }
                        CaptionSurface(captions: model.visibleCaptions, canvas: model.format.size, localTime: model.currentOffset, interactionEnabled: model.canOpenCaptionEditor, companionProfile: model.companionProfile) { id in
                            if model.captions.contains(where: { $0.id == id }) { model.beginCaptionEditing(id) }
                            else { model.beginLiveCaptionEditing() }
                        }
                            .frame(width: max(0, width), height: max(0, height))
                    }
                    .frame(width: max(0, width), height: max(0, height)).clipped()
                }
                VStack {
                    HStack {
                        if model.speech.isRecording || model.isTranscribing {
                            HStack(spacing: 5) {
                                Circle().fill(StudioPalette.coral).frame(width: 6, height: 6)
                                Text(model.isTranscribing ? model.capturePhaseMessage : "画面已暂停 · 正在录制")
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(model.capturePhaseMessage)
                            }
                                .font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                }.padding(14).foregroundStyle(.white)
                if model.isPreparingCaptionEdit {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在确认识别…").font(.system(size: 12))
                    }.padding(15).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("captionEditor.preparing")
                }
                if model.isExporting { ExportOverlay(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.07)) }
            .accessibilityLabel("短片预览").accessibilityIdentifier("preview.canvas")
        }
    }
}

private struct ExportOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "sparkles.tv").font(.system(size: 26, weight: .light))
            Text("正在导出\(model.exportKindLabel)").font(.system(size: 16, weight: .medium))
            ProgressView(value: model.exportProgress).frame(width: 190).tint(StudioPalette.coral)
                .accessibilityLabel("导出进度").accessibilityIdentifier("export.progress")
            Text("\(Int(model.exportProgress * 100))% · 请稍等片刻")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            Button("取消导出", action: model.cancelExport).buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("export.cancel")
        }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(StudioPalette.cinema.opacity(0.94))
    }
}

private struct TransportPanel: View {
    @ObservedObject var model: AppModel
    @StateObject private var presentation = TransportPresentation()
    private var recordTitle: String {
        if model.isTranscribing { return "处理中…" }
        return model.speech.isRecording ? "录制中 · 点击结束" : "开始口述"
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 11) {
                Text(timeLabel(model.currentTime)).font(.system(size: 10, weight: .medium, design: .monospaced)).frame(width: 37, alignment: .leading)
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }), in: 0...max(0.01, model.totalDuration))
                    .disabled(!model.canEditStructure)
                    .accessibilityLabel("播放进度").accessibilityIdentifier("playback.seek")
                Text(timeLabel(model.totalDuration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioPalette.muted).frame(width: 37, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Button { model.seek(to: model.currentTime - 3) } label: {
                    ZStack { Image(systemName: "gobackward").font(.system(size: 19)); Text("3").font(.system(size: 8, weight: .semibold)).offset(y: 1) }
                        .frame(width: 24, height: 30)
                }.help("回退三秒").accessibilityLabel("回退三秒").accessibilityIdentifier("playback.back")
                    .disabled(!model.canEditStructure)
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: 27, height: 30)
                }.help(model.speech.isRecording ? "结束口述后自动继续播放" : "播放 / 暂停 空格").disabled(!model.canEditStructure)
                    .accessibilityLabel(model.isPlaying ? "暂停画面" : "播放画面").accessibilityIdentifier("playback.toggle")
                Spacer(minLength: 5)
                recordControl
                Spacer(minLength: 5)
                Button(action: model.addWrittenCaption) { Label("写一句", systemImage: "square.and.pencil").font(.system(size: 11)) }
                    .disabled(!model.canEditStructure)
                    .accessibilityIdentifier("caption.add")
            }.buttonStyle(.borderless)
            transcription
        }
        .sheet(isPresented: $presentation.showSpeechSettings) { SpeechSettingsSheet(model: model).interactiveDismissDisabled() }
    }

    private var recordControl: some View {
        HStack(spacing: 0) {
            Button(action: model.toggleRecording) {
                HStack(spacing: 8) {
                    if model.isTranscribing { ProgressView().controlSize(.mini).tint(.white) }
                    else { Image(systemName: model.speech.isRecording ? "stop.fill" : "mic.fill").font(.system(size: 13)) }
                    Text(recordTitle).font(.system(size: 14, weight: .semibold)).fixedSize()
                    if !model.isTranscribing {
                        Text("R").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                    }
                }.foregroundStyle(.white).padding(.horizontal, 17).frame(height: 42)
            }
            .buttonStyle(.plain).disabled(model.isTranscribing || model.isBusy || model.isExporting || model.isCheckingSpeech || model.isAutoEditing || model.isOrdering)
            .accessibilityLabel(recordTitle).accessibilityIdentifier("capture.toggle")
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 17)
            Menu {
                ForEach(CaptionStyle.allCases) { style in
                    Button { model.captionStyle = style } label: {
                        if style == model.captionStyle { Label(style == .companion ? "小人气泡 · 无声" : style.rawValue, systemImage: "checkmark") }
                        else { Text(style == .companion ? "小人气泡 · 无声" : style.rawValue) }
                    }.accessibilityIdentifier("capture.style.\(style.id)")
                }
                Divider()
                Button("捏我的小人…", action: model.beginCompanionEditing)
                    .accessibilityIdentifier("capture.companion.edit")
            } label: { Text(model.captionStyle.rawValue).font(.system(size: 11, weight: .medium)).foregroundColor(.white) }
            .menuStyle(.borderlessButton).menuIndicator(.visible).foregroundColor(.white).frame(width: model.captionStyle == .companion ? 84 : 58, height: 42)
            .help("选择字幕、贴纸、手记或无声小人气泡；口述内容仍只转为文字。")
            .disabled(!model.canEditStructure)
            .accessibilityLabel("新感想样式，\(model.captionStyle.rawValue)").accessibilityIdentifier("capture.style")
        }.background(StudioPalette.coral, in: Capsule())
    }

    private var transcription: some View {
        HStack(alignment: .center, spacing: 11) {
            if model.isTranscribing {
                CaptureProcessingStatus(message: model.capturePhaseMessage, transcript: model.speech.transcript,
                    canCancel: model.canCancelRecordingPreparation, cancel: model.cancelRecordingPreparation)
            } else if model.speech.isRecording {
                AudioMeter(level: Double(model.speech.audioLevel))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.speech.transcript.isEmpty
                        ? (model.speechMode == .localAI ? "正在录制，结束后自动识别并整理…" : "正在听，说说你看到的这一刻…")
                        : model.speech.transcript)
                        .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("capture.transcript")
                    Text("画面已暂停 · 按 R 结束后自动继续").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                        .help(model.speech.status).accessibilityIdentifier("capture.status")
                }
            } else if model.isCheckingSpeech {
                ProgressView().controlSize(.small)
                Text("正在检查语音识别…").font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                Spacer()
            } else if model.isAutoEditing {
                ProgressView().controlSize(.small)
                Text("正在分析画面与音乐节奏…").font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                Spacer()
            } else if model.isOrdering {
                ProgressView().controlSize(.small)
                Text("正在整理素材顺序…").font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                Spacer()
            } else {
                Image(systemName: "quote.opening").foregroundStyle(StudioPalette.coral.opacity(0.65))
                Text(model.speechMode == .localAI ? "口述会暂停画面，结束后自动整理、落字并继续。" : "开始口述会暂停画面，结束后自动继续。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capture.status")
            }
            Menu {
                Button("语音与整理设置…") { presentation.showSpeechSettings = true }.accessibilityIdentifier("capture.speechSettings")
                Divider()
                Button("检查语音识别…", action: model.runSpeechCheck).accessibilityIdentifier("capture.checkSpeech")
            } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 23, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!model.canEditStructure).accessibilityLabel("口述选项").accessibilityIdentifier("capture.more")
        }
        .padding(.horizontal, 13).padding(.vertical, 9).frame(minHeight: 49)
        .background(model.speech.isRecording ? StudioPalette.coral.opacity(0.065) : Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CaptureProcessingStatus: View {
    var message: String
    var transcript: String
    var canCancel: Bool
    var cancel: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.system(size: 12)).lineLimit(2).help(message).accessibilityIdentifier("capture.phase")
                if !transcript.isEmpty {
                    Text(transcript).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                        .accessibilityIdentifier("capture.transcript")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("取消本句处理", action: cancel).font(.system(size: 10)).buttonStyle(.borderless).disabled(!canCancel)
                .help("取消这次尚未保存的口述，已有字幕会保留。")
                .accessibilityIdentifier("capture.cancelPreparation")
        }
    }
}

private final class TransportPresentation: ObservableObject { @Published var showSpeechSettings = false }

private struct AudioMeter: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10) { index in
                Capsule().fill(StudioPalette.coral.opacity(Double(index) / 12 < max(0.07, level) ? 0.95 : 0.18))
                    .frame(width: 3, height: CGFloat(7 + (index % 3) * 5))
            }
        }.frame(width: 48).accessibilityLabel("麦克风输入电平")
    }
}

private struct TimelineStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("故事片段").font(.system(size: 12, weight: .semibold))
                Text("\(model.clips.count) 段 · \(model.captions.count) 句感想").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                Spacer()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        TimelineItem(model: model, clip: clip, index: index)
                    }
                }.padding(2)
            }.scrollIndicators(.hidden).frame(height: 92).accessibilityIdentifier("timeline")
        }.padding(.horizontal, 22).padding(.top, 13).padding(.bottom, 12)
            .frame(height: 142).background(StudioPalette.panel.opacity(0.65))
    }
}

private struct TimelineItem: View {
    @ObservedObject var model: AppModel
    let clip: MediaClip
    let index: Int
    private var active: Bool { model.currentClip?.id == clip.id }
    private var selected: Bool { model.selectedClipID == clip.id }
    private var count: Int { model.captions.filter { $0.clipID == clip.id }.count }
    var body: some View {
        Button { model.selectClip(clip) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let image = model.thumbnails[clip.id] { Image(nsImage: image).resizable().scaledToFill() }
                        else { StudioPalette.line }
                    }.frame(width: 107, height: 61).clipped()
                    HStack(spacing: 3) {
                        if clip.timingLocked == true { Image(systemName: "lock.fill").font(.system(size: 7)) }
                        Text(String(format: "%.1fs", clip.duration)).font(.system(size: 8, weight: .medium, design: .monospaced))
                    }
                        .foregroundStyle(.white).padding(4).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                }.frame(width: 107, height: 61)
                .overlay(alignment: .topLeading) {
                    if clip.livePhotoStillURL != nil { LivePhotoBadge(compact: true).padding(4) }
                }
                .overlay(alignment: .leading) {
                    if active {
                        GeometryReader { geometry in
                            Rectangle().fill(StudioPalette.coral)
                                .frame(width: 2, height: geometry.size.height)
                                .offset(x: geometry.size.width * min(1, max(0, model.currentOffset / clip.duration)))
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 4) {
                    Text(String(format: "%02d", index + 1)).font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                    Text(clip.name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if count > 0 { Image(systemName: "quote.bubble.fill").font(.system(size: 8)).foregroundStyle(StudioPalette.coral); Text("\(count)").font(.system(size: 8)).foregroundStyle(StudioPalette.coral) }
                }.frame(width: 107)
            }.padding(5).background(selected ? StudioPalette.coral.opacity(0.055) : .white.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? StudioPalette.coral : (active ? StudioPalette.ink.opacity(0.5) : StudioPalette.line.opacity(0.7)), lineWidth: selected ? 1.5 : 1) }
        }.buttonStyle(.plain).disabled(!model.canEditStructure)
            .help(clip.name).accessibilityLabel("跳到第 \(index + 1) 段，\(clip.livePhotoStillURL != nil ? "实况，" : "")\(clip.name)")
            .accessibilityValue(selected ? "已选中" : "")
            .accessibilityIdentifier("timeline.clip.\(clip.id.uuidString)")
            .contextMenu {
                Button("从项目移除", role: .destructive) { model.removeClip(clip.id) }
                    .disabled(!model.canEditStructure).accessibilityIdentifier("timeline.removeMenu.\(clip.id.uuidString)")
                Divider()
                Text("原文件保留")
            }
    }
}

private struct InspectorPanel: View {
    @ObservedObject var model: AppModel
    @StateObject private var presentation = InspectorPresentation()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                companionCard
                if model.clips.isEmpty { emptyInstruction }
                else { captionSection }
                if let clip = model.selectedClip {
                    divider
                    DisclosureGroup(isExpanded: $presentation.clipSettingsExpanded) {
                        ClipInspector(model: model, clip: clip).padding(.top, 13)
                    } label: { Text("片段设置").font(.system(size: 12, weight: .semibold)) }
                        .accessibilityIdentifier("clip.settings")
                }
                divider
                musicSection
            }.padding(.horizontal, 18).padding(.vertical, 21)
        }.scrollIndicators(.hidden).background(StudioPalette.panel.opacity(0.6)).accessibilityIdentifier("inspector")
    }
    private var companionCard: some View {
        Button(action: model.beginCompanionEditing) {
            HStack(spacing: 10) {
                CompanionThumbnail(profile: model.companionProfile).frame(width: 43, height: 54)
                    .background(StudioPalette.paper, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的小人").font(.system(size: 12, weight: .semibold))
                    Text(model.companionProfile.name.isEmpty ? "捏一个自己的旅伴" : model.companionProfile.displayName)
                        .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(StudioPalette.coral)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioPalette.line.opacity(0.65)) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.canEditStructure)
            .help("捏一个专属小人，用在本作品的小人气泡里。")
            .accessibilityLabel("我的小人，\(model.companionProfile.displayName)，编辑形象")
            .accessibilityIdentifier("companion.open")
    }
    private var emptyInstruction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让画面有你的感想").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("像和朋友分享一样，说说那时的心情。映述会把它变成画面上的文字。")
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted).lineSpacing(5)
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(StudioPalette.coral)
                Text("字幕 · 贴纸 · 手记 · 小人气泡").font(.system(size: 11))
            }.padding(.top, 2)
        }
    }
    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("这一段的感想").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: model.addWrittenCaption) { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.borderless).disabled(!model.canEditStructure)
                    .help("写一句感想").accessibilityLabel("写一句感想").accessibilityIdentifier("caption.add.inspector")
            }
            if let clip = model.selectedClip {
                Text(clip.name).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1).truncationMode(.middle).help(clip.name)
                if clip.livePhotoStillURL != nil {
                    Label("实况 · 使用配对的动态画面", systemImage: "livephoto")
                        .font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                }
            }
            if model.currentClipCaptions.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "quote.bubble").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(StudioPalette.coral.opacity(0.65))
                    Text("这一刻，有什么想说的？").font(.system(size: 12))
                    Text("按 R 开口，或点 + 写下来。").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 24).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(model.currentClipCaptions) { caption in CaptionEditCard(model: model, original: caption) }
            }
        }
    }
    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("配乐", systemImage: "music.note").font(.system(size: 12, weight: .semibold))
            Picker("配乐", selection: Binding<String>(get: { model.musicID ?? "none" }, set: { model.setMusicSelection($0 == "none" ? nil : $0) })) {
                Text("无配乐").tag("none")
                ForEach(model.musicTracks) { Text($0.name).tag($0.id) }
                if model.customMusicURL != nil { Text(model.customMusicURL?.deletingPathExtension().lastPathComponent ?? "自选音乐").tag("custom") }
            }.labelsHidden().disabled(!model.canEditStructure).accessibilityIdentifier("music.selection")
            if let track = model.musicTracks.first(where: { $0.id == model.musicID }) {
                Text(track.detail).font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            }
            HStack {
                Image(systemName: "speaker.wave.1").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                Slider(value: Binding(get: { model.musicVolume }, set: model.setMusicVolume), in: 0...1)
                    .accessibilityLabel("配乐音量").accessibilityIdentifier("music.volume")
                Text("\(Int(model.musicVolume * 100))%").font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioPalette.muted).frame(width: 30)
            }.disabled(!model.canEditStructure || model.musicID == nil)
            HStack(spacing: 13) {
                Button(action: model.toggleMusicPreview) {
                    Label(model.isPreviewingMusic ? "停止试听" : "试听", systemImage: model.isPreviewingMusic ? "stop.fill" : "play.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless).disabled(model.selectedMusicURL == nil || (!model.canEditStructure && !model.isPreviewingMusic))
                .accessibilityIdentifier("music.preview")
                Button(action: model.chooseCustomMusic) { Label("本地音乐…", systemImage: "folder").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(!model.canEditStructure).accessibilityIdentifier("music.custom")
            }
            if let attribution = model.selectedMusicAttribution {
                DisclosureGroup(isExpanded: $presentation.attributionExpanded) {
                    Text(attribution).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3).textSelection(.enabled).padding(.top, 5)
                } label: { Text("来源与署名").font(.system(size: 10)).foregroundStyle(StudioPalette.muted) }
                    .accessibilityIdentifier("music.attribution")
            } else {
                Text(model.musicID == "custom" ? "请确认这首音乐允许用于你的视频。" : "内置配乐可随短片分享。")
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(4)
                    .help("内置两首自制配乐采用 CC0 1.0 授权。自选音乐需有相应使用权限。")
            }
            Rectangle().fill(StudioPalette.line.opacity(0.7)).frame(height: 1).padding(.vertical, 2)
            if let previewID = model.remotePreviewTrackID {
                RemoteMusicPreviewStatus(isLoading: model.isLoadingRemoteMusicPreview,
                    message: model.remoteMusicPreviewMessage,
                    trackName: model.onlineMusicResults.first(where: { $0.id == previewID })?.name,
                    stop: model.stopOnlineMusicPreview)
            }
            if model.downloadingMusicID != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在下载配乐…").font(.system(size: 10))
                    Spacer(minLength: 0)
                    Button("取消下载", action: model.cancelMusicDownload).font(.system(size: 10)).buttonStyle(.borderless)
                        .accessibilityIdentifier("music.download.cancel")
                }
            }
            DisclosureGroup(isExpanded: $presentation.musicBrowserExpanded) {
                MusicBrowserContent(query: $model.musicSearchQuery, state: musicBrowserState,
                    actions: MusicBrowserActions(search: { model.searchOnlineMusic() },
                        searchQuery: { model.searchOnlineMusic(query: $0) }, recommend: model.refreshMusicRecommendations,
                        download: model.downloadAndUseMusic, cancelDownload: model.cancelMusicDownload,
                        preview: model.toggleOnlineMusicPreview))
                    .padding(.top, 11)
            } label: {
                HStack(spacing: 5) {
                    Text("推荐与联网曲库").font(.system(size: 12, weight: .semibold))
                    if !model.onlineMusicResults.isEmpty {
                        Text("\(min(6, model.onlineMusicResults.count)) 首").font(.system(size: 10)).foregroundStyle(StudioPalette.coral)
                    } else if model.isSearchingMusic { ProgressView().controlSize(.mini) }
                }
            }.accessibilityIdentifier("music.browser")
            if !presentation.musicBrowserExpanded && !model.recommendedMusicQueries.isEmpty {
                Text(model.musicRecommendationSummary).font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    .lineSpacing(3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(model.musicRecommendationSummary).accessibilityIdentifier("music.recommendation.collapsedSummary")
            }
            Rectangle().fill(StudioPalette.line.opacity(0.7)).frame(height: 1).padding(.vertical, 2)
            automaticEditControls
        }
    }

    private var musicBrowserState: MusicBrowserState {
        MusicBrowserState(results: model.onlineMusicResults, isSearching: model.isSearchingMusic,
            downloadingID: model.downloadingMusicID, message: model.musicSearchMessage,
            recommendation: model.musicRecommendationSummary, queries: model.recommendedMusicQueries,
            isAnalyzing: model.isAnalyzingMusic, canAnalyze: !model.clips.isEmpty && model.canEditStructure,
            canSearch: model.canEditStructure, canUse: model.canEditStructure, selectedMusicID: model.musicID,
            previewTrackID: model.remotePreviewTrackID, isPreviewLoading: model.isLoadingRemoteMusicPreview,
            previewMessage: model.remoteMusicPreviewMessage)
    }

    private var automaticEditControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("智能编排", isOn: Binding(get: { model.automaticEditEnabled }, set: model.setAutomaticEditEnabled))
                .font(.system(size: 12, weight: .semibold)).toggleStyle(.switch).controlSize(.small)
                .disabled(!model.canEditStructure).accessibilityIdentifier("autoEdit.enabled")
                .help("分析画面内容与配乐节奏，安排不同片段时长；保留已锁定的手动时长。")
            if model.isAutoEditing {
                HStack {
                    Text(model.musicID == nil ? "画面内容分析" : "画面分析 · 音乐卡点").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Text("\(Int(automaticProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                }
                ProgressView(value: automaticProgress).tint(StudioPalette.coral)
                    .accessibilityLabel("智能编排进度").accessibilityIdentifier("autoEdit.progress")
                if !model.autoEditSummary.isEmpty {
                    Text(model.autoEditSummary).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                        .help(model.autoEditSummary).accessibilityIdentifier("autoEdit.currentStep")
                }
                Button("取消编排", action: model.cancelAutomaticEdit).font(.system(size: 11)).buttonStyle(.borderless)
                    .accessibilityIdentifier("autoEdit.cancel")
            } else {
                Text(model.autoEditSummary.isEmpty ? (model.musicID == nil ? "按画面内容安排时长，可加入配乐卡点。" : "按画面内容与配乐节奏，安排不同片段时长。") : model.autoEditSummary)
                    .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(model.autoEditSummary)
                    .accessibilityIdentifier("autoEdit.summary")
                Button(action: model.arrangeAutomatically) { Label("重新编排", systemImage: "waveform.path").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(!model.automaticEditEnabled || model.clips.isEmpty || !model.canEditStructure)
                    .accessibilityIdentifier("autoEdit.arrange")
            }
        }
    }
    private var automaticProgress: Double { model.autoEditProgress.isFinite ? max(0, min(1, model.autoEditProgress)) : 0 }
    private var divider: some View { Rectangle().fill(StudioPalette.line).frame(height: 1) }
}

private final class InspectorPresentation: ObservableObject {
    @Published var clipSettingsExpanded = false
    @Published var musicBrowserExpanded = false
    @Published var attributionExpanded = false
}

/// Shared by the inspector and its offscreen fixtures. The model owns all connection/playback state.
struct RemoteMusicPreviewStatus: View {
    let isLoading: Bool
    let message: String
    let trackName: String?
    let stop: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.mini) }
                else { Image(systemName: "speaker.wave.2").font(.system(size: 10)).foregroundStyle(StudioPalette.coral) }
                Text(isLoading ? "连接 / 缓冲中" : "正在试听").font(.system(size: 10, weight: .medium))
                Spacer(minLength: 2)
                Button("停止试听", action: stop).font(.system(size: 10)).buttonStyle(.borderless)
                    .fixedSize().accessibilityIdentifier("music.remotePreview.stop")
                    .help("停止当前联网试听；已选配乐保留。")
            }
            if let trackName, !trackName.isEmpty, !message.contains(trackName) {
                Text(trackName).font(.system(size: 10, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).help(trackName)
                    .accessibilityIdentifier("music.remotePreview.trackName")
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true).help(message)
                    .accessibilityIdentifier("music.remotePreview.detail")
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.coral.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityIdentifier("music.remotePreview.status")
    }
}

struct MusicBrowserState {
    var results: [OnlineMusicTrack] = []
    var isSearching = false
    var downloadingID: String?
    var message = ""
    var recommendation = ""
    var queries: [String] = []
    var isAnalyzing = false
    var canAnalyze = false
    var canSearch = false
    var canUse = false
    var selectedMusicID: String?
    var previewTrackID: String?
    var isPreviewLoading = false
    var previewMessage = ""
}

struct MusicBrowserActions {
    var search: () -> Void = {}
    var searchQuery: (String) -> Void = { _ in }
    var recommend: () -> Void = {}
    var download: (OnlineMusicTrack) -> Void = { _ in }
    var cancelDownload: () -> Void = {}
    var preview: (OnlineMusicTrack) -> Void = { _ in }
}

struct MusicBrowserContent: View {
    @Binding var query: String
    var state: MusicBrowserState
    var actions: MusicBrowserActions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画面仅在本机分析；联网只发送关键词。曲目保留来源与署名。")
                .font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
            HStack(spacing: 7) {
                Button(action: actions.recommend) { Label("按画面推荐关键词", systemImage: "viewfinder").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(!state.canAnalyze || state.isAnalyzing)
                    .accessibilityIdentifier("music.recommend")
                if state.isAnalyzing { ProgressView().controlSize(.mini) }
            }
            if !state.recommendation.isEmpty {
                Text(state.recommendation).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3).lineLimit(3).help(state.recommendation)
                    .accessibilityIdentifier("music.recommendation.summary")
            }
            if !state.queries.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(state.queries.prefix(3)), id: \.self) { word in
                        Button { actions.searchQuery(word) } label: {
                            Text(word).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity).padding(.horizontal, 5).padding(.vertical, 5)
                                .background(StudioPalette.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(!state.canSearch || state.downloadingID != nil)
                            .help("在联网曲库搜索：\(word)").accessibilityIdentifier("music.query.\(word)")
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("例如：海边、轻快、钢琴", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { if canSearch { actions.search() } }
                    .disabled(!state.canSearch || state.downloadingID != nil)
                    .accessibilityLabel("联网配乐关键词").accessibilityIdentifier("music.search.query")
                Button(action: actions.search) { Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 20, height: 22) }
                    .buttonStyle(.borderless).disabled(!canSearch).accessibilityLabel("搜索联网曲库").accessibilityIdentifier("music.search.submit")
            }
            if state.isSearching {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("正在搜索曲库…").font(.system(size: 10)).foregroundStyle(StudioPalette.muted) }
                    .accessibilityIdentifier("music.search.progress")
            }
            if !state.message.isEmpty {
                Text(state.message).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3).lineLimit(3).help(state.message)
                    .accessibilityIdentifier("music.search.message")
                if state.results.isEmpty && !state.isSearching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("重新搜索", action: actions.search).font(.system(size: 10)).buttonStyle(.borderless).disabled(!canSearch)
                        .accessibilityIdentifier("music.search.retry")
                }
            }
            if !state.previewMessage.isEmpty {
                Text(state.previewMessage).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineSpacing(3)
                    .lineLimit(3).help(state.previewMessage).accessibilityIdentifier("music.preview.message")
            }
            if !state.results.isEmpty {
                Text("先试听片段；下载后才用于成片。").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            }
            ForEach(Array(state.results.prefix(6)), id: \.id) { track in
                OnlineMusicResultRow(track: track, selected: state.selectedMusicID == "online:\(track.id)",
                    downloading: state.downloadingID == track.id,
                    previewing: state.previewTrackID == track.id, previewLoading: state.isPreviewLoading && state.previewTrackID == track.id,
                    canDownload: state.canUse && state.downloadingID == nil && !state.isSearching, canPreview: state.canUse,
                    use: { actions.download(track) }, cancel: actions.cancelDownload, preview: { actions.preview(track) })
            }
        }.accessibilityIdentifier("music.browser.content")
    }
    private var canSearch: Bool { state.canSearch && !state.isSearching && state.downloadingID == nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct OnlineMusicResultRow: View {
    let track: OnlineMusicTrack
    let selected: Bool
    let downloading: Bool
    let previewing: Bool
    let previewLoading: Bool
    let canDownload: Bool
    let canPreview: Bool
    let use: () -> Void
    let cancel: () -> Void
    let preview: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(track.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(track.name)
            Text(track.artist).font(.system(size: 10)).foregroundStyle(StudioPalette.muted).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 7) {
                Text(track.license).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioPalette.coral).lineLimit(1).truncationMode(.middle).help(track.license)
                if let duration = track.duration, duration.isFinite && duration > 0 {
                    Text(timeLabel(duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                }
                Spacer(minLength: 0)
                Link("来源", destination: track.sourceURL).font(.system(size: 10)).accessibilityIdentifier("music.source.\(track.id)")
                Link("许可", destination: track.licenseURL).font(.system(size: 10)).accessibilityIdentifier("music.license.\(track.id)")
            }
            HStack(spacing: 8) {
                Button(action: preview) {
                    HStack(spacing: 4) {
                        if previewLoading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: previewing ? "stop.fill" : "play.circle") }
                        Text(previewing ? "停止试听" : "试听片段")
                    }
                }
                .buttonStyle(.borderless).disabled(!canPreview && !previewing)
                .help(previewLoading ? "停止连接或缓冲中的试听；当前配乐不变" : (previewing ? "停止试听；当前配乐不变" : "试听一小段，不更换配乐或加入曲库"))
                .accessibilityLabel(previewLoading ? "停止试听，连接或缓冲中，\(track.name)" : (previewing ? "停止试听，\(track.name)" : "试听片段，\(track.name)"))
                .accessibilityIdentifier("music.remotePreview.\(track.id)")
                Spacer(minLength: 0)
                if downloading {
                    ProgressView().controlSize(.mini)
                    Button("取消下载", action: cancel).buttonStyle(.borderless)
                        .accessibilityIdentifier("music.download.cancel.\(track.id)")
                } else if selected {
                    Label("正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(StudioPalette.coral)
                } else {
                    Button(action: use) { Label("下载并使用", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderless).disabled(!canDownload).accessibilityIdentifier("music.download.\(track.id)")
                }
            }.font(.system(size: 10))
            if previewLoading {
                Text("连接 / 缓冲中…").font(.system(size: 9)).foregroundStyle(StudioPalette.muted)
                    .accessibilityIdentifier("music.remotePreview.buffering.\(track.id)")
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(StudioPalette.line.opacity(0.7)) }
        .accessibilityIdentifier("music.result.\(track.id)")
    }
}

private struct ClipInspector: View {
    @ObservedObject var model: AppModel
    let clip: MediaClip
    private func clipBinding(_ path: WritableKeyPath<MediaClip, Double>) -> Binding<Double> {
        Binding(get: { model.clips.first(where: { $0.id == clip.id })?[keyPath: path] ?? clip[keyPath: path] }, set: { value in
            var updated = model.clips.first(where: { $0.id == clip.id }) ?? clip
            updated[keyPath: path] = value; model.updateClip(updated)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(clip.name).font(.system(size: 11, weight: .medium)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if clip.livePhotoStillURL != nil {
                Label("实况照片 · 播放动态片段", systemImage: "livephoto").font(.system(size: 10)).foregroundStyle(StudioPalette.coral)
            }
            HStack {
                Text(clip.kind == .image ? "照片停留" : "片段时长").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                Spacer()
                numberField(clipBinding(\.duration), label: "秒", width: 54, accessibilityLabel: "片段时长，秒", identifier: "clip.duration.\(clip.id.uuidString)")
            }
            if clip.timingLocked == true {
                HStack {
                    Label("手动时长已锁定", systemImage: "lock.fill").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Button("恢复自动") { model.unlockTiming(clip.id) }.font(.system(size: 10)).buttonStyle(.borderless)
                        .help("解除手动锁定；开启智能编排时，会自动重新编排。")
                        .accessibilityIdentifier("clip.unlockTiming.\(clip.id.uuidString)")
                }
            }
            if clip.kind == .video {
                HStack {
                    Text("从原片第").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    numberField(clipBinding(\.trimStart), label: "秒开始", width: 54, accessibilityLabel: "原视频起点，秒", identifier: "clip.trimStart.\(clip.id.uuidString)")
                }
                Text("原片共 \(String(format: "%.1f", clip.sourceDuration)) 秒").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
            }
            HStack(spacing: 8) {
                Button { model.moveClip(clip.id, by: -1) } label: { Label("前移", systemImage: "arrow.left").font(.system(size: 11)) }
                    .disabled(model.clips.first?.id == clip.id)
                    .accessibilityIdentifier("clip.moveEarlier.\(clip.id.uuidString)")
                Button { model.moveClip(clip.id, by: 1) } label: { Label("后移", systemImage: "arrow.right").font(.system(size: 11)) }
                    .disabled(model.clips.last?.id == clip.id)
                    .accessibilityIdentifier("clip.moveLater.\(clip.id.uuidString)")
                Spacer()
                Button { model.removeClip(clip.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }.help("移除此片段，原文件会保留")
                    .accessibilityLabel("移除片段").accessibilityIdentifier("clip.delete.\(clip.id.uuidString)")
            }.buttonStyle(.borderless)
        }.disabled(!model.canEditStructure)
    }
}

struct CaptionStyleSelector: View {
    @Binding var selection: CaptionStyle
    var identifier: String
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(CaptionStyle.allCases) { style in
                Button { selection = style } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selection == style ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                        Text(style.rawValue).font(.system(size: 10, weight: selection == style ? .semibold : .regular))
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selection == style ? StudioPalette.coral : StudioPalette.ink)
                        .background(selection == style ? StudioPalette.coral.opacity(0.08) : StudioPalette.paper, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .help(style == .companion ? "无声小人陪伴画面，口述仍只转为文字。" : "将这句感想设为\(style.rawValue)")
                    .accessibilityLabel(style == .companion ? "小人气泡，无声" : style.rawValue)
                    .accessibilityValue(selection == style ? "已选中" : "")
                    .accessibilityIdentifier("\(identifier).\(style.id)")
            }
        }.accessibilityIdentifier(identifier)
    }
}

private struct CaptionEditCard: View {
    @ObservedObject var model: AppModel
    let original: Caption
    @StateObject private var presentation = CaptionPresentation()
    private var caption: Caption { model.captions.first { $0.id == original.id } ?? original }
    private var selected: Bool { model.selectedCaptionID == original.id }
    private func binding<T>(_ path: WritableKeyPath<Caption, T>) -> Binding<T> {
        Binding(get: { caption[keyPath: path] }, set: { value in var copy = caption; copy[keyPath: path] = value; model.updateCaption(copy) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(caption.style.rawValue).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioPalette.coral).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(StudioPalette.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                Text("\(timeLabel(caption.start))–\(timeLabel(caption.start + caption.duration))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioPalette.muted)
                Spacer()
                Button {
                    model.selectedCaptionID = caption.id
                    let start = model.clips.startTime(of: caption.clipID)
                    model.pause(); model.seek(to: start + caption.start)
                } label: { Image(systemName: "play.circle").font(.system(size: 12)) }.buttonStyle(.borderless).help("预览这句感想")
                    .accessibilityLabel("定位这句感想").accessibilityIdentifier("caption.preview.\(caption.id.uuidString)")
                Button { model.deleteCaption(caption.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }.buttonStyle(.borderless).help("删除这句感想")
                    .accessibilityLabel("删除这句感想").accessibilityIdentifier("caption.delete.\(caption.id.uuidString)")
            }
            if selected {
                TextEditor(text: binding(\.text)).font(.system(size: 13)).lineSpacing(4)
                    .scrollContentBackground(.hidden).padding(5).frame(height: 83)
                    .background(StudioPalette.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("感想文字").accessibilityIdentifier("caption.text.\(caption.id.uuidString)")
                HStack {
                    Button { model.beginCaptionCleanup(caption.id) } label: { Label("整理文字", systemImage: "text.badge.checkmark").font(.system(size: 11)) }
                        .buttonStyle(.borderless).help("基础整理可处理空白与标点；AI 可用时还可生成建议。")
                        .accessibilityIdentifier("caption.cleanup.\(caption.id.uuidString)")
                    Spacer()
                }
                CaptionStyleSelector(selection: binding(\.style), identifier: "caption.style.\(caption.id.uuidString)")
                if caption.style == .companion {
                    Button("编辑我的小人…", action: model.beginCompanionEditing)
                        .font(.system(size: 10)).buttonStyle(.borderless)
                        .accessibilityIdentifier("caption.companion.\(caption.id.uuidString)")
                }
                DisclosureGroup(isExpanded: $presentation.timeExpanded) {
                    timeControls.padding(.top, 9)
                } label: { Text("显示时间").font(.system(size: 10)).foregroundStyle(StudioPalette.muted) }
                    .accessibilityIdentifier("caption.timing.\(caption.id.uuidString)")
            } else {
                Button { model.selectedCaptionID = caption.id } label: {
                    Text(caption.text.isEmpty ? "点击编辑这句感想" : caption.text)
                        .font(.system(size: 12)).lineSpacing(4).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).accessibilityLabel("编辑感想，\(caption.text)")
                .accessibilityIdentifier("caption.edit.\(caption.id.uuidString)")
            }
            if let originalText = caption.originalTranscript, originalText != caption.text {
                CaptionOriginalTextPanel(originalText: originalText, expanded: $presentation.originalExpanded,
                    restore: { model.restoreCaptionOriginal(caption.id) }, identifier: "caption.original.\(caption.id.uuidString)")
            }
        }
        .padding(11).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? StudioPalette.coral.opacity(0.55) : StudioPalette.line.opacity(0.6)) }
        .onTapGesture { model.selectedCaptionID = caption.id }
        .disabled(!model.canEditStructure)
        .accessibilityIdentifier("caption.card.\(caption.id.uuidString)")
    }
    private var timeControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("开始").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    numberField(binding(\.start), label: "秒", width: 56, accessibilityLabel: "感想开始时间，秒", identifier: "caption.start.\(caption.id.uuidString)")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("持续").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                    numberField(binding(\.duration), label: "秒", width: 56, accessibilityLabel: "感想持续时间，秒", identifier: "caption.duration.\(caption.id.uuidString)")
                }
                Spacer(minLength: 0)
            }
            Button("整段显示") { model.fillClip(caption.id) }.font(.system(size: 10)).buttonStyle(.borderless)
                .accessibilityIdentifier("caption.fill.\(caption.id.uuidString)")
        }
    }
}

private final class CaptionPresentation: ObservableObject {
    @Published var timeExpanded = false
    @Published var originalExpanded = false
}

struct CaptionOriginalTextPanel: View {
    var originalText: String
    @Binding var expanded: Bool
    var restore: () -> Void
    var identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(expanded ? "收起原文" : "查看原文") { expanded.toggle() }
                    .accessibilityIdentifier("\(identifier).toggle")
                Spacer(minLength: 0)
                Button("还原识别文字", action: restore).help("用识别原文替换这句文字；可以撤销。")
                    .accessibilityIdentifier("\(identifier).restore")
            }.font(.system(size: 10)).buttonStyle(.borderless)
            if expanded {
                ScrollView { Text(originalText).font(.system(size: 11)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 80).padding(8).background(StudioPalette.paper, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("\(identifier).text")
            }
        }.accessibilityIdentifier(identifier)
    }
}

private func numberField(_ value: Binding<Double>, label: String, width: CGFloat, accessibilityLabel: String, identifier: String) -> some View {
    HStack(spacing: 4) {
        TextField("0", value: value, format: .number.precision(.fractionLength(1)))
            .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: width)
            .accessibilityLabel(accessibilityLabel).accessibilityIdentifier(identifier)
        Text(label).font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView { let view = PlayerLayerView(); view.videoLayer.player = player; return view }
    func updateNSView(_ nsView: PlayerLayerView, context: Context) { nsView.videoLayer.player = player }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayerLayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

private final class PlayerLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; layer?.addSublayer(videoLayer)
        videoLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { .zero }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit() }
}

private struct ImageSurface: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> SourceImageView {
        let view = SourceImageView()
        view.imageScaling = .scaleProportionallyUpOrDown; view.imageAlignment = .alignCenter
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ nsView: SourceImageView, context: Context) {
        nsView.updateSource(url)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SourceImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class SourceImageView: NSImageView {
    private(set) var sourceURL: URL?
    private var attemptedFile: SourceImageFileSignature?

    func updateSource(_ url: URL, loadImage: (URL) -> NSImage? = { MediaEngine.previewImage(url: $0) }) {
        if sourceURL != url {
            sourceURL = url
            image = nil
            attemptedFile = nil
        }
        // A healthy preview stays cached across playback updates. Failed files
        // are decoded again only after the file appears or its identity changes.
        guard image == nil else { return }
        let signature = SourceImageFileSignature(url: url)
        guard signature != attemptedFile else { return }
        attemptedFile = signature
        guard signature?.isReadable == true else { return }
        image = loadImage(url)
    }

    override var intrinsicContentSize: NSSize { .zero }
}

private struct SourceImageFileSignature: Equatable {
    var size: UInt64
    var modificationDate: Date
    var fileNumber: UInt64
    var permissions: UInt16
    var isReadable: Bool

    init?(url: URL) {
        let path = url.resolvingSymlinksInPath().path
        guard url.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        isReadable = FileManager.default.isReadableFile(atPath: path)
    }
}

private struct CaptionSurface: NSViewRepresentable {
    let captions: [Caption]
    let canvas: CGSize
    let localTime: Double
    let interactionEnabled: Bool
    var companionProfile: CompanionProfile = .classic
    let onActivate: (UUID) -> Void
    func makeNSView(context: Context) -> CaptionLayerView { CaptionLayerView() }
    func updateNSView(_ nsView: CaptionLayerView, context: Context) {
        nsView.update(captions: captions, canvas: canvas, localTime: localTime, interactionEnabled: interactionEnabled, companionProfile: companionProfile, onActivate: onActivate)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaptionLayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct CaptionPreviewHitRegion {
    var captionID: UUID
    var clipID: UUID
    var frame: CGRect
}

@MainActor protocol CaptionPreviewHitTesting: AnyObject {
    var captionHitRegions: [CaptionPreviewHitRegion] { get }
    func captionID(atViewPoint point: CGPoint) -> UUID?
}

private final class CaptionLayerView: NSView, CaptionPreviewHitTesting {
    private let captionRoot = CALayer()
    private let hoverOutline = CALayer()
    private var displayed: [Caption] = []
    private var displayedCompanionProfile: CompanionProfile = .classic
    private var renderedLayers: [CALayer] = []
    private var hitButtons: [UUID: CaptionHitButton] = [:]
    private var canvas = CGSize.zero
    private var localTime: Double?
    private var interactionEnabled = false
    private var onActivate: ((UUID) -> Void)?
    private var hoveredID: UUID?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; layer?.addSublayer(captionRoot)
        captionRoot.anchorPoint = .zero
        hoverOutline.isHidden = true
        hoverOutline.backgroundColor = NSColor.clear.cgColor
        hoverOutline.borderColor = NSColor(calibratedRed: 0.88, green: 0.32, blue: 0.25, alpha: 0.9).cgColor
        hoverOutline.zPosition = 1000
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard captionID(atViewPoint: local) != nil else { return nil }
        return super.hitTest(point)
    }
    var captionHitRegions: [CaptionPreviewHitRegion] {
        guard canvas.width > 0, canvas.height > 0 else { return [] }
        let scaleX = bounds.width / canvas.width, scaleY = bounds.height / canvas.height
        return renderedLayers.compactMap { layer in
            guard let idString = layer.value(forKey: "captionID") as? String, let id = UUID(uuidString: idString),
                  let clipString = layer.value(forKey: "clipID") as? String, let clipID = UUID(uuidString: clipString) else { return nil }
            let rect = layer.frame
            return CaptionPreviewHitRegion(captionID: id, clipID: clipID,
                frame: CGRect(x: bounds.minX + rect.minX * scaleX, y: bounds.minY + rect.minY * scaleY,
                              width: rect.width * scaleX, height: rect.height * scaleY))
        }
    }
    func captionID(atViewPoint point: CGPoint) -> UUID? {
        guard interactionEnabled, bounds.contains(point) else { return nil }
        return captionHitRegions.reversed().first(where: { $0.frame.contains(point) })?.captionID
    }
    @MainActor func update(captions: [Caption], canvas: CGSize, localTime: Double, interactionEnabled: Bool, companionProfile: CompanionProfile = .classic, onActivate: @escaping (UUID) -> Void) {
        let contentChanged = captions != displayed || canvas != self.canvas
        let motionChanged = captions.contains(where: { $0.style == .companion }) && localTime != self.localTime
        let appearanceChanged = captions.contains(where: { $0.style == .companion }) && companionProfile.visualKey != displayedCompanionProfile.visualKey
        displayedCompanionProfile = companionProfile
        self.localTime = localTime
        self.interactionEnabled = interactionEnabled; self.onActivate = onActivate
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if contentChanged || motionChanged || appearanceChanged {
            displayed = captions; self.canvas = canvas
            if contentChanged {
                hoveredID = nil
                hitButtons.values.forEach { $0.removeFromSuperview() }; hitButtons = [:]
            }
            captionRoot.sublayers?.forEach { $0.removeFromSuperlayer() }
            renderedLayers = MediaEngine.renderedCaptions(captions, canvas: canvas, localTime: localTime, companionProfile: companionProfile)
            for rendered in renderedLayers {
                captionRoot.addSublayer(rendered)
                guard let idString = rendered.value(forKey: "captionID") as? String, let id = UUID(uuidString: idString),
                      let caption = captions.first(where: { $0.id == id }), hitButtons[id] == nil else { continue }
                let button = CaptionHitButton(frame: .zero)
                button.captionID = id; button.title = ""; button.isBordered = false; button.focusRingType = .none
                button.target = self; button.action = #selector(activateCaption(_:))
                button.toolTip = "点击修改：\(caption.text)"
                button.setAccessibilityLabel("修改画面文字：\(caption.text)")
                button.setAccessibilityIdentifier("preview.caption.\(id.uuidString)")
                button.onHover = { [weak self] inside in self?.setHovered(inside ? id : nil) }
                addSubview(button); hitButtons[id] = button
            }
            captionRoot.addSublayer(hoverOutline)
        }
        updateTransform(); CATransaction.commit()
    }
    @objc private func activateCaption(_ button: CaptionHitButton) {
        guard interactionEnabled, let id = button.captionID else { return }
        onActivate?(id)
    }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); updateTransform(); CATransaction.commit()
    }
    private func updateTransform() {
        guard canvas.width > 0, canvas.height > 0 else { return }
        captionRoot.bounds = CGRect(origin: .zero, size: canvas)
        captionRoot.position = .zero
        captionRoot.setAffineTransform(CGAffineTransform(scaleX: bounds.width / canvas.width, y: bounds.height / canvas.height))
        for region in captionHitRegions {
            guard let button = hitButtons[region.captionID] else { continue }
            let changed = button.frame != region.frame || button.isEnabled != interactionEnabled
            if button.frame != region.frame { button.frame = region.frame }
            button.isEnabled = interactionEnabled
            if changed { button.updateTrackingAreas(); window?.invalidateCursorRects(for: button) }
        }
        updateHoverOutline()
    }
    private func setHovered(_ id: UUID?) {
        guard hoveredID != id else { return }
        hoveredID = id
        CATransaction.begin(); CATransaction.setDisableActions(true); updateHoverOutline(); CATransaction.commit()
    }
    private func updateHoverOutline() {
        guard interactionEnabled, let id = hoveredID,
              let layer = renderedLayers.first(where: { ($0.value(forKey: "captionID") as? String) == id.uuidString }) else {
            hoverOutline.isHidden = true; return
        }
        hoverOutline.frame = layer.frame
        hoverOutline.cornerRadius = min(canvas.width, canvas.height) / 1080 * 11
        hoverOutline.borderWidth = max(1, canvas.width / max(1, bounds.width)) * 1.5
        hoverOutline.isHidden = false
    }
}

private final class CaptionHitButton: NSButton {
    var captionID: UUID?
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    // Caption artwork is drawn by the shared renderer; this native control supplies only input and accessibility.
    override func draw(_ dirtyRect: NSRect) {}
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        super.updateTrackingAreas()
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
