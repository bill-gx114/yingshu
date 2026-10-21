import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation
import QuartzCore
import SwiftUI

/// Own-source rendering only. The test never displays a window, activates an app,
/// reads the desktop, accesses microphone input, or loads a user's saved project.
@main
struct RenderChecks {
    private static let defaultsSuite = "YingShu.RenderChecks.\(UUID().uuidString)"
    private static let profileDefaults = UserDefaults(suiteName: defaultsSuite)!
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        defer { profileDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Tests/output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            fputs("FAIL: own-view rendering exceeded 35 seconds; check layout or caption-renderer loops.\n", stderr)
            Darwin.exit(124)
        }
        var reports: [RenderReport] = []
        try checkSourceImageRecovery(root: root)

        let empty = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, profileDefaults: profileDefaults)
        reports.append(try render(name: "empty-1120x760", size: CGSize(width: 1120, height: 760), model: empty, output: output))
        await empty.prepareToTerminate()

        let landscape = try sampleModel(root: root, format: .landscape)
        reports.append(try render(name: "landscape-1280x800", size: CGSize(width: 1280, height: 800), model: landscape, output: output))
        await landscape.prepareToTerminate()

        let missingProject = try sampleModel(root: root, format: .landscape)
        missingProject.setProjectTitle("秋天的海岸与山野 · 想把每个慢慢走过的瞬间都留给未来自己的旅行")
        missingProject.clips[1].url = root.appendingPathComponent("Tests/fixtures/moved/已经移动的山间照片.png")
        missingProject.refreshMissingProjectAssets()
        precondition(missingProject.missingProjectAssets.count == 1, "A missing original must remain discoverable inside the editor")
        precondition(missingProject.hasUnsavedProjectChanges, "The editor must mark changes that have not reached a named project file")
        reports.append(try render(name: "missing-assets-banner-1120x760", size: CGSize(width: 1120, height: 760), model: missingProject, output: output))
        await missingProject.prepareToTerminate()

        let unavailableAssets = [
            MissingProjectAsset(id: "fixture-live", url: URL(fileURLWithPath: "/Volumes/映述布局示例/一次慢慢走完的旅行/已移动的原始素材/海边傍晚/IMG_20261019_很长的实况照片文件名.HEIC"), label: "海边傍晚与慢慢落下的太阳 · 实况照片", kind: .livePhoto),
            MissingProjectAsset(id: "fixture-music", url: URL(fileURLWithPath: "/Volumes/映述布局示例/一次慢慢走完的旅行/配乐/海岸边慢慢吹来的风与一个不用赶路的下午.m4a"), label: "海岸边慢慢吹来的风与一个不用赶路的下午", kind: .music)
        ]
        let missingFixtures: [(String, MissingAssetsFixture)] = [
            ("missing-assets-sheet-640x490", MissingAssetsFixture(assets: unavailableAssets)),
            ("missing-assets-validating-640x490", MissingAssetsFixture(assets: unavailableAssets, isRelinking: true)),
            ("missing-assets-error-640x490", MissingAssetsFixture(assets: unavailableAssets, issue: "所选照片与动态视频并非同一张实况，请重新选择配对的两个文件。")),
            ("missing-assets-long-error-640x490", MissingAssetsFixture(assets: unavailableAssets, issue: "所选文件无法覆盖原剪辑的 00:04–00:18。\n原文件位置：/Volumes/映述布局示例/一次慢慢走完的旅行/原始素材/需要保留完整文件名的很长中文目录/海边傍晚的完整动态视频.MOV\n请从原始素材文件夹选择完整视频；感想、顺序和剪辑时间均已保留。\n如果素材保存在外置硬盘，请先连接硬盘。iCloud 中的素材需要先下载到本机，再重新选择。\n可以稍后继续关联其余素材，或点击完成返回编辑器。")),
            ("missing-assets-final-validating-640x490", MissingAssetsFixture(assets: [], isRelinking: true)),
            ("missing-assets-complete-640x490", MissingAssetsFixture(assets: [], issue: "上一次选择的文件不匹配；此时素材已在 Finder 中归位。"))
        ]
        for (name, fixture) in missingFixtures {
            reports.append(try render(name: name, size: CGSize(width: 640, height: 490), model: empty, output: output,
                missingAssetsFixture: fixture))
        }
        let recoveryFixtures: [(String, RecoverySaveFixture)] = [
            ("recovery-pending-420x60", RecoverySaveFixture(state: .pending, label: "正在自动保留…", detail: "正在写入本机恢复副本。")),
            ("recovery-saved-420x60", RecoverySaveFixture(state: .saved(Date(timeIntervalSince1970: 1_792_368_000)), label: "已自动保留", detail: "本机恢复副本写入成功。")),
            ("recovery-failed-420x120", RecoverySaveFixture(state: .failed("恢复目录不可写"), label: "恢复副本保存失败", detail: "恢复目录不可写，尚未保存本次修改。\n可重试，或用 ⌘S 将项目保存到其他位置。"))
        ]
        for (name, fixture) in recoveryFixtures {
            let height: CGFloat = { if case .failed = fixture.state { return 120 }; return 60 }()
            reports.append(try render(name: name, size: CGSize(width: 420, height: height), model: empty, output: output,
                recoverySaveFixture: fixture))
        }

        let portrait = try sampleModel(root: root, format: .portrait)
        reports.append(try render(name: "portrait-1280x800", size: CGSize(width: 1280, height: 800), model: portrait, output: output))
        await portrait.prepareToTerminate()

        let product = try sampleModel(root: root, format: .landscape)
        product.title = "海边散步的一天"
        for index in product.clips.indices { product.clips[index].duration = 4 }
        let texts = ["那天下午什么也没做，\n却是整趟旅行最舒服的时候。", "慢一点，才能听见山里的风。", "想把这样的傍晚，多留一会儿。"]
        let styles: [CaptionStyle] = [.sticker, .note, .subtitle]
        product.captions = product.clips.enumerated().map { index, clip in
            Caption(clipID: clip.id, start: 0, duration: 4, text: texts[index], style: styles[index])
        }
        product.selectedClipID = product.clips.first?.id
        product.selectedCaptionID = product.captions.first?.id
        product.currentTime = 0.5
        product.status = "示例项目 · 三段画面，三种心情。"
        guard await product.ensureAutomaticEdit() else {
            throw RenderFailure.message("Product preview automatic edit failed: \(product.errorMessage ?? product.status)")
        }
        print("Product automatic durations: \(product.clips.map { String(format: "%.2f", $0.duration) }.joined(separator: ", "))")
        reports.append(try render(name: "product-preview-1280x800", size: CGSize(width: 1280, height: 800), model: product, output: output))
        await product.prepareToTerminate()

        let originalText = "那个，那天下午什么也没做，嗯，却是整趟旅行最舒服的时候。"
        let finalizedText = "那天下午什么也没做，却是整趟旅行最舒服的时候。"
        let originalView = try sampleModel(root: root, format: .landscape)
        let originalCaption = Caption(clipID: originalView.clips[0].id, start: 0, duration: 6,
            text: finalizedText, style: .sticker, originalTranscript: originalText)
        originalView.captions = [originalCaption]; originalView.selectedCaptionID = originalCaption.id
        originalView.speechMode = .localAI
        originalView.status = "布局示例 · 整理后的文字可查看原文，不代表本测试调用了 AI。"
        reports.append(try render(name: "caption-original-1280x800", size: CGSize(width: 1280, height: 800), model: originalView, output: output))
        originalView.restoreCaptionOriginal(originalCaption.id)
        precondition(originalView.captions.first?.text == originalText, "The original-text action restores recognition text")
        originalView.undoEdit()
        precondition(originalView.captions.first?.text == finalizedText, "One undo restores the text before the original-text action")
        await originalView.prepareToTerminate()

        for (name, phase) in [("local-ai-loading-1280x800", "首次加载本地 AI 识别与整理模型，请稍候；可取消本句处理。"),
                              ("local-ai-finishing-1280x800", "正在识别并整理这句口述，语音和文字只在本机处理。") ] {
            let speech = LayoutSpeech(phase: phase)
            let processing = try sampleModel(root: root, format: .landscape, speechInput: speech)
            processing.captions = [Caption(clipID: processing.clips[0].id, start: 0, duration: 6, text: finalizedText, style: .sticker)]
            processing.selectedCaptionID = processing.captions.first?.id
            processing.title = "本地 AI 状态布局验证"
            processing.speechMode = .localAI; processing.isTranscribing = true
            processing.status = "布局示例 · 相同空转写内容，分别展示加载与收尾的真实阶段字段。"
            precondition(processing.capturePhaseMessage == phase && processing.canCancelRecordingPreparation,
                "Processing UI must use the authoritative phase message, not infer it from an empty transcript")
            reports.append(try render(name: name, size: CGSize(width: 1280, height: 800), model: processing, output: output))
            processing.isTranscribing = false
            await processing.prepareToTerminate()
        }

        let companion = try sampleModel(root: root, format: .landscape)
        guard let companionClip = companion.clips.first else { throw RenderFailure.message("Missing companion fixture clip") }
        let companionCaption = Caption(clipID: companionClip.id, start: 0, duration: 6,
            text: "慢慢走吧，\n今天的风景只属于这一刻。", style: .companion)
        companion.title = "小人气泡 · 无声陪伴"
        companion.captions = [companionCaption]
        companion.selectedCaptionID = companionCaption.id
        companion.captionStyle = .companion
        companion.currentTime = 0.1
        companion.status = "无声小人气泡 · 口述仍只转为文字。"
        reports.append(try render(name: "companion-landscape-1280x800", size: CGSize(width: 1280, height: 800), model: companion,
            output: output, advanceCompanionTimeTo: 1.4))
        companion.format = .portrait
        companion.currentTime = 0.1
        reports.append(try render(name: "companion-portrait-1280x800", size: CGSize(width: 1280, height: 800), model: companion,
            output: output, advanceCompanionTimeTo: 1.4))
        companion.format = .landscape
        let personalProfile = CompanionProfile(name: "小栗", skinTone: .honey, hairStyle: .curls,
            hairColor: .chestnut, faceShape: .oval, outfitColor: .sage, glassesStyle: .round)
        var photoInspiredProfile = personalProfile
        photoInspiredProfile.portraitTraits = CompanionPortraitTraits(eyeShape: .smiling, eyeSpacing: .wide, smile: .sunny)
        let photoSummary = "参考了照片里的暖蜜肤色、栗棕发色与笑眼，做成更圆润的小人。发型与眼镜可以继续自己选。原照片未保存。"
        try await CompanionStickerRenderer.prepare(personalProfile)
        reports.append(try render(name: "companion-personal-paused-1280x800", size: CGSize(width: 1280, height: 800), model: companion,
            output: output, switchCompanionProfileTo: personalProfile))
        for (name, height, fixture) in [
            ("companion-editor-760x660", CGFloat(660), CompanionEditorFixture(profile: personalProfile)),
            ("companion-editor-compact-760x560", CGFloat(560), CompanionEditorFixture(profile: personalProfile)),
            ("companion-editor-preparing-760x560", CGFloat(560), CompanionEditorFixture(profile: personalProfile, isPreparing: true)),
            ("companion-editor-error-760x660", CGFloat(660), CompanionEditorFixture(profile: personalProfile,
                error: "暂时无法准备这个造型，请重新尝试。之前的小旅伴还在，当前项目没有改变。")),
            ("companion-photo-analyzing-760x660", CGFloat(660), CompanionEditorFixture(profile: personalProfile, isAnalyzingPhoto: true)),
            ("companion-photo-analyzing-760x560", CGFloat(560), CompanionEditorFixture(profile: personalProfile, isAnalyzingPhoto: true)),
            ("companion-photo-suggestion-760x660", CGFloat(660), CompanionEditorFixture(profile: photoInspiredProfile, photoSummary: photoSummary)),
            ("companion-photo-suggestion-760x560", CGFloat(560), CompanionEditorFixture(profile: photoInspiredProfile, photoSummary: photoSummary)),
            ("companion-photo-error-760x660", CGFloat(660), CompanionEditorFixture(profile: personalProfile,
                error: "照片里有不止一张脸，请选一张清楚的单人正面照。当前小人的造型没有改变。")),
            ("companion-photo-error-760x560", CGFloat(560), CompanionEditorFixture(profile: personalProfile,
                error: "暂时无法读取这张照片。请从照片 App 导出 JPEG 或 HEIC，再重新选择；当前造型和作品都已保留。"))
        ] {
            reports.append(try render(name: name, size: CGSize(width: 760, height: height), model: companion,
                output: output, companionEditorFixture: fixture))
        }
        await companion.prepareToTerminate()

        let arranging = try sampleModel(root: root, format: .landscape)
        arranging.title = product.title
        arranging.clips = product.clips
        arranging.captions = product.captions
        arranging.thumbnails = product.thumbnails
        arranging.selectedClipID = product.selectedClipID
        arranging.selectedCaptionID = product.selectedCaptionID
        arranging.currentTime = 0.5
        arranging.arrangeAutomatically()
        precondition(arranging.isAutoEditing && !arranging.canEditStructure, "Automatic editing must lock normal edits before its Task starts")
        reports.append(try render(name: "auto-editing-1280x800", size: CGSize(width: 1280, height: 800), model: arranging, output: output, settlingPasses: 0))
        arranging.cancelAutomaticEdit()
        await arranging.prepareToTerminate()

        let ordering = try sampleModel(root: root, format: .landscape)
        ordering.clips = product.clips
        ordering.captions = product.captions
        ordering.thumbnails = product.thumbnails
        ordering.selectedClipID = product.selectedClipID
        ordering.selectedCaptionID = product.selectedCaptionID
        ordering.currentTime = 0.5
        ordering.reapplyOrder()
        precondition(ordering.isOrdering && !ordering.canEditStructure, "Ordering must lock normal edits before its Task starts")
        reports.append(try render(name: "ordering-1280x800", size: CGSize(width: 1280, height: 800), model: ordering, output: output, settlingPasses: 0))
        ordering.cancelOrdering()
        _ = await ordering.waitForOrdering()
        await ordering.prepareToTerminate()

        let live = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, profileDefaults: profileDefaults)
        let stillURL = root.appendingPathComponent("Tests/fixtures/live-photo/iphone-style-still.heic")
        let movieURL = root.appendingPathComponent("Tests/fixtures/live-photo/iphone-style-motion.mov")
        guard FileManager.default.isReadableFile(atPath: stillURL.path), FileManager.default.isReadableFile(atPath: movieURL.path) else {
            throw RenderFailure.message("The system-validated Live Photo fixture is missing; no ordinary image will be mislabeled as a Live Photo.")
        }
        await live.importURLs([stillURL, movieURL], arrange: false)
        guard live.clips.count == 1, let liveClip = live.clips.first,
              liveClip.kind == .video, liveClip.livePhotoStillURL == stillURL else {
            throw RenderFailure.message("The real Live Photo resource pair did not import as one dynamic clip: \(live.errorMessage ?? live.status)")
        }
        live.title = "实况照片导入验证"
        let liveCaption = Caption(clipID: liveClip.id, start: 0, duration: min(2.5, liveClip.duration), text: "实况照片，会保留配对的动态画面。", style: .sticker)
        live.captions = [liveCaption]
        live.selectedCaptionID = liveCaption.id
        live.seek(to: min(0.5, liveClip.duration / 2))
        live.status = "实况配对测试 · 使用系统验证通过的照片与动态视频。"
        for _ in 0..<10 where live.player.currentItem?.status != .readyToPlay { try? await Task.sleep(nanoseconds: 50_000_000) }
        reports.append(try render(name: "live-photo-1280x800", size: CGSize(width: 1280, height: 800), model: live, output: output))
        await live.prepareToTerminate()

        let editor = try sampleModel(root: root, format: .landscape)
        guard let editID = editor.captions.first?.id else { throw RenderFailure.message("Missing caption editor fixture") }
        editor.beginCaptionEditing(editID)
        precondition(editor.editingCaptionID == editID && !editor.isPlaying, "Caption editing opens with the picture paused")
        editor.captionEditDraft = "那天下午什么也没做，\n却是整趟旅行最舒服的时候。"
        reports.append(try render(name: "caption-editor-520x620", size: CGSize(width: 520, height: 620), model: editor, output: output, captionEditorOnly: true))
        let edited = editor.captionEditDraft
        editor.saveCaptionEditing()
        precondition(editor.editingCaptionID == nil && editor.captions.first(where: { $0.id == editID })?.text == edited, "Explicit completion updates the rendered caption")
        editor.beginCaptionEditing(editID)
        editor.captionEditDraft = "取消不应覆盖原文字"
        editor.cancelCaptionEditing()
        precondition(editor.captions.first(where: { $0.id == editID })?.text == edited, "Cancel leaves the original caption intact")
        await editor.prepareToTerminate()

        let stillOnly = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, profileDefaults: profileDefaults)
        await stillOnly.importURLs([stillURL], arrange: false)
        guard stillOnly.clips.count == 1, stillOnly.clips[0].kind == .image,
              stillOnly.clips[0].livePhotoStillURL == nil, stillOnly.importSummary != nil, stillOnly.errorMessage == nil else {
            throw RenderFailure.message("A photo without its selected companion should produce a non-blocking import summary")
        }
        stillOnly.title = "文件导入提示"
        reports.append(try render(name: "import-summary-1280x800", size: CGSize(width: 1280, height: 800), model: stillOnly, output: output))
        stillOnly.clearImportSummary()
        precondition(stillOnly.importSummary == nil && stillOnly.importDetails.isEmpty, "Import notice can be cleared independently of its media")
        await stillOnly.prepareToTerminate()

        // Static, explicitly local-only presentation fixtures. No search/download callback is invoked.
        let musicModel = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, profileDefaults: profileDefaults)
        var tracks: [OnlineMusicTrack] = []
        for index in 1...7 {
            let name = index == 1 ? "海岸边慢慢吹来的风与一个不用赶路的下午" : "原创测试曲目 \(index) · 轻柔钢琴"
            let artist = index == 1 ? "布局测试作者 · 这不是线上搜索结果" : "独立布局示例作者"
            let audioURL = URL(string: "https://example.invalid/audio-\(index).mp3")!
            let sourceURL = URL(string: "https://example.invalid/track/\(index)")!
            let licenseURL = URL(string: "https://example.invalid/license/\(index)")!
            let track = OnlineMusicTrack(id: "layout-\(index)", name: name, artist: artist,
                audioURL: audioURL, sourceURL: sourceURL,
                license: index.isMultiple(of: 2) ? "CC0 1.0" : "CC BY 4.0", licenseURL: licenseURL,
                duration: Double(110 + index * 8))
            tracks.append(track)
        }
        let browser = MusicBrowserState(results: tracks, message: "布局示例 · 7 条输入仅显示前 6 条；所有链接均为无效测试域名。",
            recommendation: "画面以海岸、山野和傍晚为主，适合舒缓器乐。此句为离屏布局数据，不是实际推荐。",
            queries: ["海边 轻柔", "钢琴 慢节奏", "温暖 傍晚"], canAnalyze: true, canSearch: true, canUse: true,
            selectedMusicID: "online:layout-1")
        reports.append(try render(name: "music-results-280x1260", size: CGSize(width: 280, height: 1260), model: musicModel,
            output: output, musicBrowserState: browser))
        var downloading = browser
        downloading.results = Array(tracks.prefix(2)); downloading.downloadingID = "layout-2"
        downloading.message = "正在下载并核验音乐与许可…"
        reports.append(try render(name: "music-download-280x680", size: CGSize(width: 280, height: 680), model: musicModel,
            output: output, musicBrowserState: downloading))
        var searching = browser
        searching.results = []; searching.isSearching = true; searching.isAnalyzing = true
        searching.message = "正在检索可用于视频的配乐…"
        reports.append(try render(name: "music-search-280x480", size: CGSize(width: 280, height: 480), model: musicModel,
            output: output, musicBrowserState: searching))
        var failed = searching
        failed.isSearching = false; failed.isAnalyzing = false
        failed.message = "网络暂不可用，请稍后重试；已选配乐保持不变。"
        reports.append(try render(name: "music-retry-280x480", size: CGSize(width: 280, height: 480), model: musicModel,
            output: output, musicBrowserState: failed))
        var previewing = browser
        previewing.results = Array(tracks.prefix(2)); previewing.previewTrackID = "layout-2"
        previewing.previewMessage = "正在试听《原创测试曲目 2 · 轻柔钢琴》；当前配乐保留。"
        reports.append(try render(name: "music-preview-playing-280x680", size: CGSize(width: 280, height: 680), model: musicModel,
            output: output, musicBrowserState: previewing))
        var preparing = previewing
        preparing.isPreviewLoading = true; preparing.canUse = false
        preparing.previewMessage = "正在连接《原创测试曲目 2 · 轻柔钢琴》，等待首段缓冲；可停止试听。"
        reports.append(try render(name: "music-preview-loading-280x680", size: CGSize(width: 280, height: 680), model: musicModel,
            output: output, musicBrowserState: preparing))
        var buffering = previewing
        buffering.isPreviewLoading = true
        buffering.previewMessage = "网络暂时停顿，正在缓冲《原创测试曲目 2 · 轻柔钢琴》；可停止试听。"
        reports.append(try render(name: "music-preview-buffering-260x800", size: CGSize(width: 260, height: 800), model: musicModel,
            output: output, musicBrowserState: buffering))
        var previewFailed = previewing
        previewFailed.previewTrackID = nil
        previewFailed.previewMessage = "试听片段暂时无法准备，请重试或打开来源查看。"
        reports.append(try render(name: "music-preview-error-280x680", size: CGSize(width: 280, height: 680), model: musicModel,
            output: output, musicBrowserState: previewFailed))
        // These are presentation-only states. No AI request or model download is started.
        let originalCleanup = "2026年10月19日，我和小林去了阿苏。  嗯，风很大，，但我们没有改去别的地方。"
        let aiUnavailable = "本机 AI 运行环境尚未准备完成。基础整理仍可用，输入音频与文字不会外发。"
        let longCleanup = Array(repeating: originalCleanup + "\n那天下午我们慢慢走，看了很久的云，也没有急着回去。", count: 12).joined(separator: "\n")
        let longState = CaptionCleanupPresentationState(originalText: longCleanup, availability: aiUnavailable)
        reports.append(try render(name: "caption-cleanup-long-520x620", size: CGSize(width: 520, height: 620), model: musicModel,
            output: output, captionCleanupFixture: longState, captionFixtureDraft: longCleanup))
        let unavailable = CaptionCleanupPresentationState(issue: aiUnavailable, originalText: originalCleanup, availability: aiUnavailable)
        reports.append(try render(name: "caption-cleanup-unavailable-520x620", size: CGSize(width: 520, height: 620), model: musicModel,
            output: output, captionCleanupFixture: unavailable, captionFixtureDraft: originalCleanup))
        let cleaning = CaptionCleanupPresentationState(isCleaning: true, originalText: originalCleanup,
            availability: "布局示例：正在等待本机整理建议，不会直接改写画面文字。", canUseAI: true)
        reports.append(try render(name: "caption-cleanup-preparing-520x620", size: CGSize(width: 520, height: 620), model: musicModel,
            output: output, captionCleanupFixture: cleaning, captionFixtureDraft: originalCleanup))
        let suggestion = CaptionCleanupPresentationState(suggestion: "2026年10月19日，我和小林去了阿苏。风很大，但我们没有改去别的地方。",
            originalText: originalCleanup, availability: "布局示例：建议需先采用，采用后仍可修改草稿。", canUseAI: true)
        reports.append(try render(name: "caption-cleanup-suggestion-520x620", size: CGSize(width: 520, height: 620), model: musicModel,
            output: output, captionCleanupFixture: suggestion, captionFixtureDraft: originalCleanup))
        let settingsReady = SpeechSettingsPresentationState(engineSummary: "本机优先 · 增强中文识别已就绪",
            enhancedAvailability: .installed, downloadProgress: nil, isPreparing: false, cleanupAvailability: aiUnavailable)
        reports.append(try render(name: "speech-settings-ready-540x640", size: CGSize(width: 540, height: 640), model: musicModel,
            output: output, speechSettingsFixture: settingsReady))
        let settingsPreparing = SpeechSettingsPresentationState(engineSummary: "本机优先 · 正在准备增强中文模型",
            enhancedAvailability: .downloading, downloadProgress: 0.37, isPreparing: true, cleanupAvailability: aiUnavailable)
        reports.append(try render(name: "speech-settings-preparing-540x640", size: CGSize(width: 540, height: 640), model: musicModel,
            output: output, speechSettingsFixture: settingsPreparing))
        let aiReady = SpeechSettingsPresentationState(engineSummary: "本地 AI · 语音识别与表达整理，音频与文字不外发。",
            enhancedAvailability: .installed, downloadProgress: nil, isPreparing: false,
            cleanupAvailability: "布局示例：使用本机语音识别与表达整理，无需 API Key。", localAIReady: true,
            localAIStatus: "布局示例：本机运行组件与模型已准备。首次口述仍需加载模型，进度会显示在口述区。")
        reports.append(try render(name: "speech-settings-local-ai-ready-540x640", size: CGSize(width: 540, height: 640), model: musicModel,
            output: output, speechSettingsFixture: aiReady, speechSettingsFixtureMode: .localAI))
        let aiMissing = SpeechSettingsPresentationState(engineSummary: "本地 AI · 语音识别与表达整理，音频与文字不外发。",
            enhancedAvailability: .installed, downloadProgress: nil, isPreparing: false,
            cleanupAvailability: aiUnavailable, localAIReady: false,
            localAIStatus: "布局示例：本机 AI 组件尚未准备。Apple 本机识别模型已安装，不能代替本机 AI 运行环境。")
        reports.append(try render(name: "speech-settings-local-ai-unavailable-540x640", size: CGSize(width: 540, height: 640), model: musicModel,
            output: output, speechSettingsFixture: aiMissing, speechSettingsFixtureMode: .localAI))
        let deepSeekStates: [(String, DeepSeekSettingsPresentationState)] = [
            ("missing-key", DeepSeekSettingsPresentationState()),
            ("ready", DeepSeekSettingsPresentationState(hasAPIKey: true, isEnabled: true,
                feedback: "连接成功，已保存的 API Key 可用。")),
            ("testing", DeepSeekSettingsPresentationState(hasAPIKey: true, isEnabled: true, isTesting: true)),
            ("error", DeepSeekSettingsPresentationState(hasAPIKey: true,
                feedback: "连接未通过，请检查 API Key、账户余额与网络后重试。", feedbackIsError: true))
        ]
        for (name, deepSeekState) in deepSeekStates {
            var deepSeekSpeechState = aiReady
            if deepSeekState.isEnabled { deepSeekSpeechState.engineSummary = "本机识别 · DeepSeek 整理文字" }
            reports.append(try render(name: "speech-settings-deepseek-\(name)-540x640", size: CGSize(width: 540, height: 640), model: musicModel,
                output: output, speechSettingsFixture: deepSeekSpeechState, speechSettingsFixtureMode: .localAI,
                deepSeekFixture: deepSeekState))
        }
        await musicModel.prepareToTerminate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: output.appendingPathComponent("layout-report.json"), options: .atomic)
        let failures = reports.flatMap { report in report.errors.map { "\(report.name): \($0)" } }
        for report in reports {
            print("\(report.errors.isEmpty ? "PASS" : "FAIL"): \(report.name) · \(report.checks.count) layout checks · \(report.pixelWidth)×\(report.pixelHeight) PNG")
            for warning in report.warnings { print("  NOTE: \(warning)") }
        }
        guard failures.isEmpty else { throw RenderFailure.message(failures.joined(separator: "\n")) }
        print("Snapshots and geometry: \(output.path)")
    }

    @MainActor
    private static func checkSourceImageRecovery(root: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-preview-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = root.appendingPathComponent("Resources/demo-coast.png")
        let restoredURL = directory.appendingPathComponent("原位置归位.png")
        var attempts = 0
        let load: (URL) -> NSImage? = { url in attempts += 1; return MediaEngine.previewImage(url: url) }
        let restored = SourceImageView()
        restored.updateSource(restoredURL, loadImage: load)
        guard restored.image == nil && attempts == 0 else { throw RenderFailure.message("A missing preview must not attempt decoding") }
        try FileManager.default.copyItem(at: original, to: restoredURL)
        restored.updateSource(restoredURL, loadImage: load)
        guard restored.image != nil && attempts == 1 else { throw RenderFailure.message("A photo restored to the same URL must reload its empty preview") }
        for _ in 0..<30 { restored.updateSource(restoredURL, loadImage: load) }
        guard attempts == 1 else { throw RenderFailure.message("Healthy previews must stay cached across playback updates") }

        let corruptURL = directory.appendingPathComponent("损坏后替换.png")
        try Data("invalid image fixture".utf8).write(to: corruptURL)
        let corrupt = SourceImageView()
        corrupt.updateSource(corruptURL, loadImage: load)
        guard corrupt.image == nil && attempts == 2 else { throw RenderFailure.message("A corrupt preview must fail without retaining an old image") }
        for _ in 0..<30 { corrupt.updateSource(corruptURL, loadImage: load) }
        guard attempts == 2 else { throw RenderFailure.message("Unchanged corrupt media must not be decoded every playback frame") }
        try Data(contentsOf: original).write(to: corruptURL, options: .atomic)
        corrupt.updateSource(corruptURL, loadImage: load)
        guard corrupt.image != nil && attempts == 3 else { throw RenderFailure.message("Replacing corrupt media at its original URL must retry the preview") }
        print("PASS: Source-image recovery · 6 regression checks · own temporary fixtures only")
    }

    @MainActor
    private static func sampleModel(root: URL, format: VideoFormat, speechInput: (any SpeechInput)? = nil) throws -> AppModel {
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, speechInput: speechInput, profileDefaults: profileDefaults)
        model.title = "秋天的海岸与山野 · 一次慢慢走完的旅行"
        model.format = format
        let resources = ["demo-coast.png", "demo-hills.png", "demo-evening.png"]
        let names = ["第一天傍晚的海边与慢慢落下的太阳", "沿着山间小路继续向前走", "终于等到了城市亮灯的那一刻"]
        model.clips = try zip(resources, names).map { filename, name in
            let url = root.appendingPathComponent("Resources").appendingPathComponent(filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw RenderFailure.message("Missing original fixture: \(filename)") }
            return MediaClip(url: url, name: name, kind: .image, duration: 6, sourceDuration: 30)
        }
        for clip in model.clips { model.thumbnails[clip.id] = NSImage(contentsOf: clip.url) }
        guard let first = model.clips.first else { throw RenderFailure.message("No fixture clips") }
        let longCaption = Caption(clipID: first.id, start: 0, duration: 6,
            text: "那天下午我们沿着海边慢慢走，什么特别的事情也没有发生。风把远处的云一点点推开，太阳落下来的时候，我忽然觉得，这样不用赶路、也不用急着解释自己的时刻，已经足够值得被记住了。", style: .sticker)
        let note = Caption(clipID: first.id, start: 0, duration: 5, text: "这一刻，想和未来的自己分享。", style: .note)
        let subtitle = Caption(clipID: first.id, start: 0, duration: 4, text: "我们没有赶路，只是认真看了一次海。", style: .subtitle)
        model.captions = [longCaption, note, subtitle]
        model.selectedClipID = first.id
        model.selectedCaptionID = longCaption.id
        model.currentTime = 1
        model.status = "已载入原创示例 · 这是独立离屏测试，不读取已保存项目。"
        return model
    }

    @MainActor
    private static func render(name: String, size: CGSize, model: AppModel, output: URL, settlingPasses: Int = 10, captionEditorOnly: Bool = false, musicBrowserState: MusicBrowserState? = nil, advanceCompanionTimeTo: Double? = nil,
        switchCompanionProfileTo: CompanionProfile? = nil,
        captionCleanupFixture: CaptionCleanupPresentationState? = nil, captionFixtureDraft: String = "",
        speechSettingsFixture: SpeechSettingsPresentationState? = nil, speechSettingsFixtureMode: SpeechRecognitionMode = .localFirst,
        deepSeekFixture: DeepSeekSettingsPresentationState = DeepSeekSettingsPresentationState(),
        missingAssetsFixture: MissingAssetsFixture? = nil, recoverySaveFixture: RecoverySaveFixture? = nil,
        companionEditorFixture: CompanionEditorFixture? = nil) throws -> RenderReport {
        print("Rendering own hidden view: \(name)"); fflush(stdout)
        let musicMeasurement = MusicLayoutMeasurement()
        let content: AnyView
        let vocabularyFixture = "阿苏，太宰府，小林\n海边散步，慢慢走"
        if let companionEditorFixture {
            content = AnyView(CompanionEditorContent(profile: .constant(companionEditorFixture.profile),
                useAsDefault: .constant(false), isPreparing: companionEditorFixture.isPreparing,
                error: companionEditorFixture.error, cancel: {}, complete: {},
                isAnalyzingPhoto: companionEditorFixture.isAnalyzingPhoto,
                photoSummary: companionEditorFixture.photoSummary, choosePhoto: {}, cancelPhoto: {}))
        } else if let missingAssetsFixture {
            content = AnyView(MissingAssetsContent(assets: missingAssetsFixture.assets, isRelinking: missingAssetsFixture.isRelinking,
                issue: missingAssetsFixture.issue, locate: { _ in }, refresh: {}, done: {}))
        } else if let recoverySaveFixture {
            content = AnyView(VStack(spacing: 0) {
                RecoverySaveStatus(state: recoverySaveFixture.state, label: recoverySaveFixture.label,
                    detail: recoverySaveFixture.detail, canRetry: true, retry: {})
                    .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 30, alignment: .trailing)
                if case .failed = recoverySaveFixture.state { RecoverySaveFailureDetail(detail: recoverySaveFixture.detail) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(red: 0.992, green: 0.988, blue: 0.976)))
        } else if let captionCleanupFixture {
            content = AnyView(CaptionEditorContent(draft: .constant(captionFixtureDraft), state: captionCleanupFixture,
                actions: CaptionCleanupActions()))
        } else if let speechSettingsFixture {
            content = AnyView(SpeechSettingsContent(mode: .constant(speechSettingsFixtureMode), vocabulary: .constant(vocabularyFixture),
                state: speechSettingsFixture, deepSeek: deepSeekFixture, prepare: {}, cancelPreparation: {}, complete: {}))
        } else if let musicBrowserState {
            content = AnyView(VStack(alignment: .leading, spacing: 14) {
                Text("配乐 · 曲库布局示例").font(.system(size: 13, weight: .semibold))
                if let previewID = musicBrowserState.previewTrackID {
                    RemoteMusicPreviewStatus(isLoading: musicBrowserState.isPreviewLoading,
                        message: musicBrowserState.previewMessage,
                        trackName: musicBrowserState.results.first(where: { $0.id == previewID })?.name,
                        stop: {})
                }
                MusicBrowserContent(query: .constant("海边 轻柔 钢琴"), state: musicBrowserState, actions: MusicBrowserActions())
            }
            .padding(18).frame(width: size.width, alignment: .topLeading)
            .background(GeometryReader { proxy in Color.clear.onAppear { musicMeasurement.contentSize = proxy.size } })
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(red: 0.976, green: 0.965, blue: 0.941)))
        } else {
            content = captionEditorOnly ? AnyView(CaptionEditSheet(model: model)) : AnyView(EditorView(model: model))
        }
        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        // Run only this process's ordinary layout/update work. No existing desktop UI is queried.
        for _ in 0..<settlingPasses {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        guard !window.isVisible else { throw RenderFailure.message("Offscreen test window unexpectedly became visible") }
        var companionMotionChanged: Bool?
        var companionHitTargetsRetained: Bool?
        var companionProfileChanged: Bool?
        if advanceCompanionTimeTo != nil || switchCompanionProfileTo != nil {
            let beforeViews = descendants(of: host)
            let captionView = beforeViews.first(where: { $0 is any CaptionPreviewHitTesting })
            let initialCharacter = captionView?.layer.flatMap { layers(in: $0).first(where: { $0.name == "companion-character" }) }
            let initialImage = initialCharacter?.contents as AnyObject?
            let initialButtons = Set(beforeViews.compactMap { view -> ObjectIdentifier? in
                guard let button = view as? NSButton, button.accessibilityIdentifier().hasPrefix("preview.caption.") == true else { return nil }
                return ObjectIdentifier(button)
            })
            let initialTime = model.currentTime
            if let advanceCompanionTimeTo { model.currentTime = advanceCompanionTimeTo }
            if let switchCompanionProfileTo {
                model.beginCompanionEditing(); model.finishCompanionEditing(switchCompanionProfileTo, useAsDefault: false)
            }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
            }
            let afterViews = descendants(of: host)
            let currentView = afterViews.first(where: { $0 is any CaptionPreviewHitTesting })
            let currentCharacter = currentView?.layer.flatMap { layers(in: $0).first(where: { $0.name == "companion-character" }) }
            let currentImage = currentCharacter?.contents as AnyObject?
            if advanceCompanionTimeTo != nil { companionMotionChanged = initialImage != nil && currentImage != nil && initialImage !== currentImage }
            if let switchCompanionProfileTo {
                companionProfileChanged = initialImage != nil && currentImage != nil && initialImage !== currentImage &&
                    model.companionProfile == switchCompanionProfileTo && model.currentTime == initialTime && !model.isPlaying
            }
            let currentButtons = Set(afterViews.compactMap { view -> ObjectIdentifier? in
                guard let button = view as? NSButton, button.accessibilityIdentifier().hasPrefix("preview.caption.") == true else { return nil }
                return ObjectIdentifier(button)
            })
            companionHitTargetsRetained = !initialButtons.isEmpty && initialButtons == currentButtons
        }
        let scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RenderFailure.message("Could not allocate own-view snapshot bitmap")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderFailure.message("Offscreen AppKit rendering did not produce a PNG; the current WindowServer session may not support it")
        }
        try png.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
        let native = descendants(of: host)
        let geometry = native.map { view in
            ViewGeometry(type: String(describing: type(of: view)),
                         rect: RectRecord(view.convert(view.bounds, to: host)),
                         bounds: RectRecord(view.bounds),
                         intrinsicWidth: Double(view.intrinsicContentSize.width),
                         intrinsicHeight: Double(view.intrinsicContentSize.height))
        }
        var report = RenderReport(name: name, pointWidth: Int(size.width), pointHeight: Int(size.height),
                                  pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh,
                                  nativeViews: geometry, accessibility: accessibilityRecords(host: host, window: window))
        report.check(host.bounds.size == size, "Root view matches requested window size")
        report.check(!window.isVisible, "Own window remained hidden throughout rendering")
        let colors = sampledColorCount(bitmap)
        report.check(colors > (recoverySaveFixture == nil ? 15 : 5), "Snapshot contains rendered interface pixels (\(colors) sampled colors)")
        if let companionEditorFixture {
            let buttons = native.compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("companion.") }
            let actions = buttons.filter { ["companion.cancel", "companion.complete"].contains($0.accessibilityIdentifier()) }
            if actions.count == 2 {
                report.check(actions.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: host)) },
                             "Companion cancel and complete stay visible at the requested sheet size")
            } else {
                // Current SwiftUI may draw its buttons without NSButton peers.
                // Their native focus rectangles remain measurable in our owned
                // hosting view even when the hidden window's AX tree is empty.
                let footerTargets = native.filter { view in
                    guard String(describing: type(of: view)) == "_FocusRingView" else { return false }
                    var parent = view.superview
                    while let ancestor = parent {
                        if ancestor is NSScrollView { return false }
                        parent = ancestor.superview
                    }
                    return true
                }
                    .map { $0.convert($0.bounds, to: host) }
                    .filter { $0.height >= 20 && $0.midY > size.height - 90 }
                report.check(footerTargets.count >= 2 && footerTargets.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0) },
                             "Companion footer keeps two native action focus targets fully inside the requested sheet size")
                report.warnings.append("SwiftUI exposes no NSButton peers for this sheet; footer focus geometry and rendered pixels are available, but native enabled-state and action identity are not independently readable in the hidden window.")
            }
            let nameFields = native.compactMap { $0 as? NSTextField }.filter { $0.isEditable && $0.stringValue == companionEditorFixture.profile.name }
            report.check(!nameFields.isEmpty && nameFields.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: host)) },
                         "Personal companion nickname appears in a native input inside the sheet")
            let isWorking = companionEditorFixture.isPreparing || companionEditorFixture.isAnalyzingPhoto
            if isWorking && !buttons.isEmpty {
                let cancelIDs: Set<String> = companionEditorFixture.isAnalyzingPhoto ? ["companion.cancel", "companion.photo.stop"] : ["companion.cancel"]
                report.check(buttons.filter { !cancelIDs.contains($0.accessibilityIdentifier()) }.allSatisfy { !$0.isEnabled },
                             "Companion preparation and photo analysis lock option and complete controls")
                report.check(buttons.filter { cancelIDs.contains($0.accessibilityIdentifier()) }.allSatisfy(\.isEnabled),
                             "Cancel and photo-analysis stop remain enabled while work is in progress")
            }
            if !report.accessibility.isEmpty {
                let ids = Set(report.accessibility.map(\.identifier))
                for id in ["companion.editor", "companion.name", "companion.default", "companion.cancel", "companion.complete"] {
                    report.check(ids.contains(id), "Companion editor exposes accessible action: \(id)")
                }
                if companionEditorFixture.error != nil { report.check(ids.contains("companion.error"), "Companion preparation failure remains visible inside its sheet") }
                if companionEditorFixture.isAnalyzingPhoto {
                    report.check(ids.contains("companion.photo.progress") && ids.contains("companion.photo.stop"),
                                 "Photo analysis exposes its progress and a separate stop action")
                    report.check(!ids.contains("companion.photo.choose"), "Photo analysis cannot start a second photo selection")
                } else {
                    report.check(ids.contains("companion.photo.choose"), "A photo can be selected from the editor header")
                }
                if companionEditorFixture.photoSummary != nil {
                    report.check(ids.contains("companion.photo.summary"), "A photo-inspired suggestion explains its result in the editor")
                }
                if companionEditorFixture.profile.portraitTraits != nil {
                    report.check(ids.contains("companion.photo.resetTraits"), "Photo-inspired facial details can be returned to their default")
                }
            } else { report.warnings.append("Hidden-window accessibility tree unavailable; companion controls were checked through native view geometry.") }
            report.warnings.append("Companion editor presentation uses generated profiles and text only; it does not select a photo, save a default, open a user project or call an AI service.")
            return report
        }
        if let missingAssetsFixture {
            let buttons = native.compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("assets.") }
            report.check(buttons.allSatisfy { host.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: host)) },
                "Missing-asset actions stay inside the sheet width")
            if missingAssetsFixture.isRelinking, !buttons.isEmpty {
                report.check(buttons.allSatisfy { !$0.isEnabled }, "Relinking locks sheet actions until media validation finishes")
            }
            if !report.accessibility.isEmpty {
                let ids = Set(report.accessibility.map(\.identifier))
                for id in ["assets.sheet", "assets.refresh", "assets.done"] {
                    report.check(ids.contains(id), "Missing-asset sheet exposes accessible action: \(id)")
                }
                if missingAssetsFixture.assets.isEmpty {
                    report.check(ids.contains(missingAssetsFixture.isRelinking ? "assets.validating" : "assets.complete"), "The final resource confirms success only after validation finishes")
                    if missingAssetsFixture.isRelinking { report.check(!ids.contains("assets.complete"), "Pending validation cannot display a success state") }
                    report.check(!ids.contains("assets.issue"), "A completed relink does not retain a stale selection error")
                } else {
                    for asset in missingAssetsFixture.assets {
                        report.check(ids.contains("assets.locate.\(asset.id)") && ids.contains("assets.path.\(asset.id)"),
                            "Each missing resource exposes its original path and individual locate action")
                    }
                }
                if missingAssetsFixture.issue != nil && !missingAssetsFixture.assets.isEmpty {
                    report.check(ids.contains("assets.issue"), "A relinking failure stays inside its current sheet")
                }
                if missingAssetsFixture.isRelinking { report.check(ids.contains("assets.progress"), "Media validation exposes a busy state") }
            } else { report.warnings.append("The hidden-window accessibility tree is unavailable; missing-asset layout was captured through the owned native view.") }
            report.warnings.append("Missing-resource presentation uses static paths; no file chooser was opened and no user media was read or relocated.")
            return report
        }
        if let recoverySaveFixture {
            if !report.accessibility.isEmpty {
                let ids = Set(report.accessibility.map(\.identifier))
                report.check(ids.contains("recovery.message"), "Recovery status remains available to assistive technology")
                if case .failed = recoverySaveFixture.state {
                    report.check(ids.contains("recovery.retry"), "Recovery failure exposes an explicit retry action")
                    report.check(ids.contains("recovery.detail"), "Recovery failure exposes the complete reason and manual-save alternative inline")
                } else { report.check(!ids.contains("recovery.retry"), "Healthy or pending recovery state does not offer a failure action") }
            }
            report.warnings.append("Recovery status is a static presentation fixture; no recovery file was written.")
            return report
        }
        if let companionMotionChanged {
            report.check(companionMotionChanged, "Current clip time updates the companion pose inside the existing preview")
            report.check(companionHitTargetsRetained == true, "Companion motion retains the existing native caption edit hit target")
        }
        if let companionProfileChanged {
            report.check(companionProfileChanged, "Confirming a new companion look refreshes the paused picture at its unchanged playhead")
            report.check(companionHitTargetsRetained == true, "Changing companion appearance retains the existing native caption edit hit target")
        }
        if captionCleanupFixture != nil || speechSettingsFixture != nil {
            let textViews = native.compactMap { $0 as? NSTextView }.filter(\.isEditable)
            let expected = captionCleanupFixture != nil ? captionFixtureDraft : vocabularyFixture
            report.check(textViews.contains(where: { $0.string == expected }), "Sheet native editor preserves the supplied long Chinese text")
            report.check(!textViews.isEmpty && textViews.allSatisfy { $0.bounds.width > 100 && $0.bounds.width <= size.width - 30 },
                "Sheet text inputs wrap within the modal width without horizontal overflow")
            if speechSettingsFixture != nil {
                let keyFields = native.compactMap { $0 as? NSSecureTextField }
                report.check(keyFields.count == 1 && keyFields.allSatisfy { $0.stringValue.isEmpty },
                    "DeepSeek key entry uses one blank native secure field and never preloads a saved key")
                report.check(keyFields.allSatisfy { $0.bounds.width > 160 && $0.bounds.width < size.width - 30 },
                    "DeepSeek secure key input fits inside the settings width")
                if !report.accessibility.isEmpty {
                    report.check(report.accessibility.contains(where: { $0.identifier == "speechSettings.deepSeekEnabled" }),
                        "DeepSeek opt-in switch remains accessible in every configuration state")
                } else {
                    report.warnings.append("The hidden-window accessibility tree is unavailable in this session; secure-field type and geometry were verified through the owned native view tree.")
                }
            }
            report.warnings.append("Cleanup and speech-model states are static presentation fixtures; no AI generation, model preparation, microphone input or network request was started.")
            return report
        }
        if let musicBrowserState {
            let fields = native.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            report.check(fields.contains(where: { $0.stringValue == "海边 轻柔 钢琴" }), "Music search input renders the requested keyword string")
            report.check(fields.allSatisfy { field in host.bounds.insetBy(dx: -1, dy: -1).contains(field.convert(field.bounds, to: host)) }, "Music keyword input stays within the narrow inspector")
            if let measured = musicMeasurement.contentSize {
                report.check(measured.width <= size.width + 1, "Music browser content respects the requested narrow inspector width")
                report.check(measured.height <= size.height + 1, "Music browser content fits the complete layout fixture vertically")
            } else { report.errors.append("Music layout did not report its content dimensions") }
            report.check(musicBrowserState.results.allSatisfy { $0.audioURL.host == "example.invalid" && $0.sourceURL.host == "example.invalid" }, "Music layout fixture contains only non-network example.invalid URLs")
            report.warnings.append("Music catalog entries are static layout fixtures; no recommendation, network search, download, link opening, or remote playback was performed.")
            return report
        }
        if captionEditorOnly {
            let textViews = native.compactMap { $0 as? NSTextView }
            report.check(textViews.contains(where: { $0.string == model.captionEditDraft }), "Native caption text input shows the current draft")
            report.check(textViews.contains(where: { $0.isEditable }), "Caption draft has an editable native input")
            report.check(model.editingCaptionID != nil && !model.isPlaying, "Caption editor preserves the paused editing session")
            return report
        }
        let images = native.compactMap { $0 as? NSImageView }.filter { String(describing: type(of: $0)).contains("SourceImageView") }
        let players = native.filter { String(describing: type(of: $0)).contains("PlayerLayerView") }
        let sources: [NSView] = model.currentClip?.kind == .video ? players : images
        if model.clips.isEmpty {
            report.check(images.isEmpty, "Empty state creates no source image canvas")
        } else {
            if model.currentClip?.livePhotoStillURL != nil {
                report.check(model.currentClip?.kind == .video, "Imported paired Live Photo renders as dynamic video")
            }
            report.check(sources.count == 1, "Exactly one source media canvas is displayed")
            if let sourceView = sources.first {
                let bounds = sourceView.bounds
                let canvasRect = sourceView.convert(bounds, to: host)
                report.check(bounds.width > 100 && bounds.height > 100, "Preview canvas has usable dimensions")
                report.check(abs(bounds.width / max(1, bounds.height) - model.format.aspect) < 0.015, "Preview canvas matches selected output aspect ratio")
                report.check(sourceView.intrinsicContentSize == .zero, "Source media intrinsic size cannot stretch SwiftUI layout")
                if let imageView = sourceView as? NSImageView {
                    report.check(imageView.imageScaling == .scaleProportionallyUpOrDown, "Source image uses complete aspect fit")
                } else if let playerLayer = sourceView.layer?.sublayers?.compactMap({ $0 as? AVPlayerLayer }).first {
                    report.check(playerLayer.videoGravity == .resizeAspect, "Source video uses complete aspect fit")
                    if !playerLayer.isReadyForDisplay { report.warnings.append("Hidden-window AVPlayerLayer has not exposed a composited movie frame; video canvas geometry and aspect fit were verified.") }
                }
                report.check(host.bounds.insetBy(dx: -1, dy: -1).contains(canvasRect), "Source image canvas stays within editor bounds")
                report.check(bounds.width <= size.width - 198 - 280 - 46, "Preview respects both inspector columns")
                let overlays = native.filter { String(describing: type(of: $0)).contains("CaptionLayerView") }
                report.check(overlays.count == 1, "Exactly one shared caption-renderer canvas is displayed")
                if let overlay = overlays.first {
                    let overlayRect = overlay.convert(overlay.bounds, to: host)
                    report.check(abs(overlayRect.width - canvasRect.width) < 1 && abs(overlayRect.height - canvasRect.height) < 1,
                                 "Caption overlay and source image use the same canvas size")
                }
            }
        }
        if let surface = native.first(where: { $0 is any CaptionPreviewHitTesting }), let hitTesting = surface as? any CaptionPreviewHitTesting {
            let regions = hitTesting.captionHitRegions
            let visibleIDs = Set(model.visibleCaptions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
            report.check(Set(regions.map(\.captionID)) == visibleIDs, "Rendered hit regions retain exact visible caption IDs despite sorting and overlap avoidance")
            report.check(regions.allSatisfy { region in model.visibleCaptions.contains(where: { $0.id == region.captionID && $0.clipID == region.clipID }) }, "Hit regions retain their actual clip association")
            if model.canOpenCaptionEditor {
                for region in regions {
                    let center = CGPoint(x: region.frame.midX, y: region.frame.midY)
                    report.check(hitTesting.captionID(atViewPoint: center) == region.captionID, "Caption center selects its true rendered ID")
                    let parentPoint = surface.superview.map { surface.convert(center, to: $0) } ?? center
                    let nativeHit = surface.hitTest(parentPoint)
                    report.check((nativeHit as? NSButton)?.accessibilityIdentifier() == "preview.caption.\(region.captionID.uuidString)", "Native hit target exposes the matching caption accessibility ID")
                }
            }
            let background = stride(from: 0.05, through: 0.95, by: 0.1).flatMap { x in
                stride(from: 0.05, through: 0.95, by: 0.1).map { y in CGPoint(x: surface.bounds.width * x, y: surface.bounds.height * y) }
            }.first(where: { point in !regions.contains(where: { $0.frame.contains(point) }) })
            if let background {
                let parentPoint = surface.superview.map { surface.convert(background, to: $0) } ?? background
                report.check(hitTesting.captionID(atViewPoint: background) == nil && surface.hitTest(parentPoint) == nil, "Pure preview background does not open a caption editor")
            }
        }
        let identifiers = Set(report.accessibility.map(\.identifier))
        if !identifiers.isEmpty {
            let expected = model.clips.isEmpty
                ? ["project.title", "project.open", "empty.import", "empty.demo"]
                : ["project.export", "preview.format", "playback.toggle", "capture.toggle", "capture.style", "caption.add"]
            for id in expected { report.check(identifiers.contains(id), "Accessible action exists: \(id)") }
            if !model.missingProjectAssets.isEmpty {
                report.check(identifiers.contains("assets.banner") && identifiers.contains("assets.manage"), "Missing source files have an actionable editor warning")
            }
            for item in report.accessibility where item.identifier == "timeline" || item.identifier.hasPrefix("timeline.clip.") {
                if item.frame.height > 0 { report.check(item.frame.height < 105, "Timeline content stays compact: \(item.identifier)") }
            }
            if let record = report.accessibility.first(where: { $0.identifier == "capture.toggle" }), record.frame.width > 0 {
                report.check(record.frame.width >= 110 && record.frame.height >= 35, "Primary dictation button has a usable hit area")
            }
        } else {
            report.warnings.append("Hidden-window accessibility geometry was not exposed; native canvas bounds were checked directly.")
        }
        return report
    }

    private static func layers(in root: CALayer) -> [CALayer] {
        [root] + (root.sublayers ?? []).flatMap { layers(in: $0) }
    }

    @MainActor
    private static func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private static func accessibilityRecords(host: NSView, window: NSWindow) -> [AccessibilityRecord] {
        var records: [AccessibilityRecord] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, depth: Int) {
            guard depth < 60, visited.count < 5000,
                  let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted,
                  let accessible = node as? any NSAccessibilityProtocol else { return }
            if let id = accessible.accessibilityIdentifier(), !id.isEmpty {
                let rect = window.convertFromScreen(accessible.accessibilityFrame())
                records.append(AccessibilityRecord(identifier: id, label: accessible.accessibilityLabel() ?? "", frame: RectRecord(rect)))
            }
            for child in accessible.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return records
    }

    private static func sampledColorCount(_ bitmap: NSBitmapImageRep) -> Int {
        var values = Set<String>()
        let stepX = max(1, bitmap.pixelsWide / 70)
        let stepY = max(1, bitmap.pixelsHigh / 50)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    values.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        return values.count
    }
}

private struct RectRecord: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) { x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height) }
}
private struct ViewGeometry: Codable {
    var type: String
    var rect: RectRecord
    var bounds: RectRecord
    var intrinsicWidth: Double
    var intrinsicHeight: Double
}
private struct AccessibilityRecord: Codable {
    var identifier: String
    var label: String
    var frame: RectRecord
}
private struct RenderReport: Codable {
    var name: String
    var pointWidth: Int
    var pointHeight: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var nativeViews: [ViewGeometry]
    var accessibility: [AccessibilityRecord]
    var checks: [String] = []
    var warnings: [String] = []
    var errors: [String] = []
    mutating func check(_ condition: Bool, _ name: String) { if condition { checks.append(name) } else { errors.append(name) } }
}
private enum RenderFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

private struct MissingAssetsFixture {
    var assets: [MissingProjectAsset]
    var isRelinking = false
    var issue: String? = nil
}
private struct RecoverySaveFixture {
    var state: RecoverySaveState
    var label: String
    var detail: String
}
private struct CompanionEditorFixture {
    var profile: CompanionProfile
    var isPreparing = false
    var error: String? = nil
    var isAnalyzingPhoto = false
    var photoSummary: String? = nil
}

@MainActor
private final class MusicLayoutMeasurement {
    var contentSize: CGSize?
}

@MainActor
private final class LayoutSpeech: SpeechInput {
    private let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var status: String
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = false
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    init(phase: String) { status = phase }
    func start() async throws { throw RenderFailure.message("Layout fixtures must never start microphone input") }
    func stop() async -> String { transcript }
    func cancel() {}
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String {
        throw RenderFailure.message("Layout fixtures must never request speech recognition")
    }
}
