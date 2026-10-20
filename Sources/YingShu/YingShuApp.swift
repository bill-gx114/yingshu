import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isExporting {
            let alert = NSAlert(); alert.messageText = "\(model.exportKindLabel)正在导出"; alert.informativeText = "退出会取消当前导出。已有文件不会被覆盖。"; alert.addButton(withTitle: "继续等待"); alert.addButton(withTitle: "取消导出并退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        Task { await model.prepareToTerminate(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct YingShuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("映述 · 边看边说成片") {
            EditorView(model: model)
                .frame(minWidth: 1120, minHeight: 760)
                .preferredColorScheme(.light)
                .onAppear {
                    delegate.model = model
                    DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
                }
        }
        .defaultSize(width: 1440, height: 940)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建手记") { model.newProject() }.keyboardShortcut("n").disabled(!model.canEditStructure)
                Button("打开项目…") { model.openProject() }.keyboardShortcut("o").disabled(!model.canEditStructure)
                Button(model.projectURL == nil ? "保存项目…" : "保存项目") { model.saveProject() }
                    .keyboardShortcut("s").disabled(!model.canEditStructure)
                Button("另存为…") { model.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canEditStructure)
                Button("查看自动保留的项目") { model.showRecoveredProjects() }.disabled(!model.canEditStructure)
                Button("检查素材位置…") {
                    model.pause()
                    model.refreshMissingProjectAssets()
                    model.isShowingMissingAssets = true
                }.disabled(!model.canEditStructure || model.clips.isEmpty)
                Divider()
                Button("导入照片和视频…") { model.importMedia() }.keyboardShortcut("i").disabled(!model.canEditStructure)
                Divider()
                Button("导出短片…") { model.exportVideo() }.disabled(!model.canEditStructure || model.clips.isEmpty)
                Button("导出带字图片…") { model.exportCaptionImages() }
                    .disabled(!model.canEditStructure || !model.captions.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
                    else { model.undoEdit() }
                }.keyboardShortcut("z").disabled(!canUndo)
                Button("重做") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.redo() }
                    else { model.redoEdit() }
                }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!canRedo)
            }
            CommandMenu("播放与口述") {
                Button(model.isPlaying ? "暂停（空格）" : "播放（空格）") { model.togglePlayback() }
                    .disabled(!model.canEditStructure || model.clips.isEmpty)
                Button(model.speech.isRecording ? "结束口述（R）" : "开始口述（R）") { model.toggleRecording() }
                    .disabled(model.clips.isEmpty || (!model.speech.isRecording && !model.canEditStructure) || model.isTranscribing)
                Button("写一句感想") { model.addWrittenCaption() }.keyboardShortcut("t", modifiers: [.command]).disabled(!model.canEditStructure || model.clips.isEmpty)
                Button("回退三秒（←）") { model.seek(to: model.currentTime - 3) }
                    .disabled(!model.canEditStructure || model.clips.isEmpty)
                Button("前进三秒（→）") { model.seek(to: model.currentTime + 3) }
                    .disabled(!model.canEditStructure || model.clips.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("检查语音识别…") { model.runSpeechCheck() }.disabled(!model.canEditStructure)
                Button("映述使用说明") {
                    let url = Bundle.main.resourceURL?.appendingPathComponent("使用说明.md")
                    if let url { NSWorkspace.shared.open(url) }
                }
                Button("本地 AI 口述说明") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("本地AI说明.md") { NSWorkspace.shared.open(url) }
                }
                Button("素材格式与 iPhone 导入说明") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("素材格式支持.md") { NSWorkspace.shared.open(url) }
                }
                Button("配乐曲库与署名说明") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("配乐曲库说明.md") { NSWorkspace.shared.open(url) }
                }
                Button("小人气泡使用说明") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("小人气泡说明.md") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
    private var canUndo: Bool {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canUndo == true }
        return model.canEditStructure && model.undoCount > 0
    }
    private var canRedo: Bool {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canRedo == true }
        return model.canEditStructure && model.redoCount > 0
    }
}
