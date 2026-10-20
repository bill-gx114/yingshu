import AppKit
import AVFoundation
import Combine
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// All project, recovery and media fixtures live in the runner's disposable directory.
/// This backend never opens a microphone, speech model, permission panel or network connection.
@MainActor private final class ProjectCheckSpeech: SpeechInput {
    let changes = Empty<Void, Never>().eraseToAnyPublisher()
    var isRecording = false
    var transcript = ""
    var status = "项目验证语音占位"
    var audioLevel: Float = 0
    var authorizationGranted = false
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    func start() async throws { throw StudioError.message("Project checks must not record audio") }
    func stop() async -> String { "" }
    func cancel() {}
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String {
        throw StudioError.message("Project checks must not recognize audio")
    }
}

private func requireProject(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw StudioError.message(message) }
}

@main struct ProjectReliabilityChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw StudioError.message("Expected disposable fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try requireProject(root.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) || root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/"),
                           "Refusing to put reliability fixtures outside a temporary directory")
        try requireProject(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath() == root.resolvingSymlinksInPath(),
                           "Run the executable from its disposable fixture directory")
        try requireProject(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                           "The disposable fixture directory must start empty")
        let photo = root.appendingPathComponent("photo.png")
        try makePhoto(at: photo)
        let firstVideo = root.appendingPathComponent("first.mp4")
        let secondVideo = root.appendingPathComponent("second.mp4")
        try await makeVideo(at: firstVideo, red: 0.2)
        try await makeVideo(at: secondVideo, red: 0.8)
        var models: [AppModel] = []
        func makeModel(recovery: URL, restore: Bool = false, autosave: Bool = true) -> AppModel {
            let model = AppModel(restoreProject: restore, autosaveEnabled: autosave,
                                 automaticMusicSearchEnabled: false, speechInput: ProjectCheckSpeech(),
                                 recoveryFileURL: recovery)
            models.append(model)
            return model
        }

        let recovery = root.appendingPathComponent("recovery.yingshu")
        let project = root.appendingPathComponent("named.yingshu.json")
        let model = makeModel(recovery: recovery)
        // Deliberately unusual accepted timing: an accidental AI pass must be observable.
        let clip = MediaClip(url: photo, name: "已确认的停留", kind: .image, duration: 6.734, sourceDuration: 30)
        let caption = Caption(clipID: clip.id, start: 1.25, duration: 2.125, text: "保存的文字与时间都要原样找回。", style: .note)
        model.clips = [clip]; model.captions = [caption]; model.musicID = nil
        model.automaticEditEnabled = true; model.title = "原始标题"; model.changed()
        try requireProject(model.recoverySaveState == .pending && model.hasUnsavedProjectChanges,
                           "An edit must immediately be pending and dirty")
        try model.saveProject(to: project)
        try requireProject(!model.hasUnsavedProjectChanges && model.projectURL == project,
                           "Saving must establish a clean named project")
        try requireSaved(model.recoverySaveState, "A completed explicit save must also flush recovery")
        model.setProjectTitle("稍后撤销的标题")
        try requireProject(model.hasUnsavedProjectChanges && model.recoverySaveState == .pending,
                           "Editing a saved title must mark it dirty and queue recovery")
        model.undoEdit()
        try requireProject(!model.hasUnsavedProjectChanges && model.title == "原始标题",
                           "Undoing back to the saved document must clear the dirty indicator")
        try model.saveProject(to: project)
        let cleanRestore = makeModel(recovery: recovery, restore: true)
        try requireProject(cleanRestore.projectURL == project && !cleanRestore.hasUnsavedProjectChanges,
                           "A clean recovery restore must preserve the named Save destination")
        try requireProject(cleanRestore.clips == model.clips && cleanRestore.captions == model.captions,
                           "Recovery did not restore the saved timeline")
        let sharedDocument = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: project))
        let recoveryDocument = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: recovery))
        try requireProject(sharedDocument.recoveryProjectURL == nil && recoveryDocument.recoveryProjectURL == project,
                           "Only the local recovery copy may contain the named project location")
        model.setProjectTitle("尚未写入命名文件的修改")
        model.flushAutosave()
        let dirtyRestore = makeModel(recovery: recovery, restore: true)
        try requireProject(dirtyRestore.projectURL == project && dirtyRestore.title == model.title && dirtyRestore.hasUnsavedProjectChanges,
                           "Recovery must retain unsaved edits and compare them with the named project")
        print("PASS: named save, dirty state, undo to saved state, clean/dirty recovery and retained Save location")

        var legacyDocument = sharedDocument
        legacyDocument.automaticEditEnabled = nil; legacyDocument.orderMode = nil; legacyDocument.speechMode = nil
        legacyDocument.downloadedMusic = []; legacyDocument.speechVocabulary = []
        let legacyProject = root.appendingPathComponent("legacy-defaults.yingshu.json")
        let legacyRecovery = root.appendingPathComponent("legacy-recovery.yingshu")
        try write(legacyDocument, to: legacyProject)
        let legacyModel = makeModel(recovery: legacyRecovery)
        try legacyModel.applyDocument(from: legacyProject)
        try requireProject(!legacyModel.hasUnsavedProjectChanges, "Opening an older document must start clean after applying its optional defaults")
        legacyModel.flushAutosave()
        let legacyRestored = makeModel(recovery: legacyRecovery, restore: true)
        try requireProject(legacyRestored.projectURL == legacyProject && !legacyRestored.hasUnsavedProjectChanges &&
                           legacyRestored.document == legacyModel.document,
                           "A recovery copy must compare legacy nil/default and empty/nil fields semantically")
        legacyRestored.setProjectTitle("旧项目真正尚未保存的修改")
        legacyRestored.flushAutosave()
        let changedLegacy = makeModel(recovery: legacyRecovery, restore: true)
        try requireProject(changedLegacy.hasUnsavedProjectChanges && changedLegacy.title == legacyRestored.title && changedLegacy.projectURL == legacyProject,
                           "Normalizing legacy defaults must still retain a genuinely unsaved title change")
        print("PASS: legacy optional defaults stay clean across recovery while genuine unsaved edits stay dirty")

        let emptySettings = makeModel(recovery: root.appendingPathComponent("empty-settings.yingshu"))
        try requireProject(!emptySettings.hasUnsavedProjectChanges, "An untouched empty project must start clean")
        emptySettings.setVideoFormat(.portrait)
        try requireProject(emptySettings.hasUnsavedProjectChanges, "An empty project's meaningful settings must also mark it dirty")
        emptySettings.flushAutosave()
        let settingsRestore = makeModel(recovery: root.appendingPathComponent("empty-settings.yingshu"), restore: true)
        try requireProject(settingsRestore.format == .portrait && settingsRestore.hasUnsavedProjectChanges,
                           "Unnamed recovery must preserve the dirty status of settings without media")
        emptySettings.undoEdit()
        try requireProject(!emptySettings.hasUnsavedProjectChanges, "Undoing empty-project settings must return to a clean document")
        print("PASS: empty-project settings and their unnamed recovery retain an accurate dirty state")

        let unavailable = root.appendingPathComponent("not-created/recovery.yingshu")
        let failed = makeModel(recovery: unavailable)
        failed.setProjectTitle("先失败，再重试")
        try requireProject(failed.recoverySaveState == .pending, "A delayed recovery must be shown as pending")
        try await waitForRecovery(failed)
        try requireProject(failed.hasRecoverySaveFailure && !FileManager.default.fileExists(atPath: unavailable.path),
                           "A missing parent directory must report failed, never saved")
        try FileManager.default.createDirectory(at: unavailable.deletingLastPathComponent(), withIntermediateDirectories: true)
        failed.retryRecoverySave()
        try requireSaved(failed.recoverySaveState, "Retry must save after the destination becomes writable")
        let retried = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: unavailable))
        try requireProject(retried.title == failed.title && !failed.hasRecoverySaveFailure,
                           "Retry did not persist the newest document or clear failure")
        print("PASS: pending, actual write failure, retry and verified recovery contents")

        let accepted = makeModel(recovery: root.appendingPathComponent("accepted-recovery.yingshu"), autosave: false)
        try accepted.applyDocument(from: project)
        let acceptedClips = accepted.clips, acceptedCaptions = accepted.captions
        let arranged = await accepted.ensureAutomaticEdit()
        try requireProject(arranged && accepted.clips == acceptedClips && accepted.captions == acceptedCaptions && !accepted.isAutoEditing,
                           "Opening and exporting must not recompute an already accepted saved timeline")
        print("PASS: reopening preserves the exact accepted timeline during export preparation")

        let videoModel = makeModel(recovery: root.appendingPathComponent("video-recovery.yingshu"), autosave: false)
        let videoClip = try await MediaEngine.inspect(url: firstVideo)
        var videoDocument = sharedDocument
        videoDocument.clips = [videoClip]; videoDocument.captions = []; videoDocument.automaticEditEnabled = false
        let videoProject = root.appendingPathComponent("video.yingshu.json")
        try write(videoDocument, to: videoProject)
        try videoModel.applyDocument(from: videoProject)
        try requireProject((videoModel.player.currentItem?.asset as? AVURLAsset)?.url == firstVideo,
                           "Initial project preview did not load the first video")
        videoDocument.clips[0].url = secondVideo
        try write(videoDocument, to: videoProject)
        try videoModel.applyDocument(from: videoProject)
        try requireProject(videoModel.clips[0].id == videoClip.id && (videoModel.player.currentItem?.asset as? AVURLAsset)?.url == secondVideo,
                           "A same-ID clip at a new path must replace the player's old AVURLAsset")
        print("PASS: same clip ID with a new source URL replaces the preview asset")

        let prior = accepted.document, priorURL = accepted.projectURL
        var remoteMusic = sharedDocument
        remoteMusic.title = "无效文档不得替换当前项目"
        remoteMusic.musicID = "custom"
        remoteMusic.customMusicURL = URL(string: "https://example.invalid/music.wav")!
        let invalidProject = root.appendingPathComponent("remote-music.yingshu.json")
        try write(remoteMusic, to: invalidProject)
        var rejected = false
        do { try accepted.applyDocument(from: invalidProject) } catch { rejected = true }
        try requireProject(rejected && accepted.document == prior && accepted.projectURL == priorURL,
                           "A remote custom music path must be rejected before changing any current project state")
        print("PASS: invalid custom music URL is rejected without replacing the project")

        var longDocument = sharedDocument
        let longText = String(repeating: "多次口述仍要完整保留。", count: 600)
        longDocument.captions[0].text = longText
        longDocument.captions[0].originalTranscript = longText
        let longProject = root.appendingPathComponent("long-caption.yingshu.json")
        try write(longDocument, to: longProject)
        try accepted.applyDocument(from: longProject)
        try requireProject(longText.utf16.count > 4000 && accepted.captions[0].text == longText && accepted.captions[0].originalTranscript == longText,
                           "An existing long caption must remain recoverable without truncating its text or transcript")
        print("PASS: existing captions over the export limit load without losing any words")

        let repeated = makeModel(recovery: root.appendingPathComponent("repeated-takes.yingshu"), autosave: false)
        repeated.clips = [clip]; repeated.musicID = nil
        let firstTake = Caption(clipID: clip.id, start: 0, duration: 4, text: String(repeating: "甲", count: 3000), originalTranscript: "第一句原稿")
        let secondTake = Caption(clipID: clip.id, start: 1, duration: 3, text: String(repeating: "乙", count: 2000), originalTranscript: "第二句原稿")
        repeated.commitSpokenCaption(firstTake); repeated.commitSpokenCaption(secondTake)
        try requireProject(repeated.captions == [firstTake, secondTake],
                           "Repeated takes must stay intact in separate cards when merging would exceed the export limit")
        try MediaEngine.validateCaptions(repeated.captions, clips: repeated.clips)
        print("PASS: repeated overlapping takes stay exportable without dropping words or original transcripts")

        let repair = makeModel(recovery: root.appendingPathComponent("repair-recovery.yingshu"), autosave: false)
        var missingDocument = sharedDocument
        missingDocument.automaticEditEnabled = false
        missingDocument.clips[0].url = root.appendingPathComponent("missing-photo.png")
        var repeatedClip = missingDocument.clips[0]
        repeatedClip.id = UUID(); repeatedClip.duration = 3.5
        missingDocument.clips.append(repeatedClip)
        let missingProject = root.appendingPathComponent("missing.yingshu.json")
        try write(missingDocument, to: missingProject)
        try repair.applyDocument(from: missingProject)
        repair.refreshMissingProjectAssets()
        try requireProject(repair.missingProjectAssets.count == 1 && repair.missingProjectAssets[0].kind == .image,
                           "Repeated references to one missing photo must produce one actionable repair")
        let missingPhoto = repair.missingProjectAssets[0]
        let beforeWrongKind = repair.document
        rejected = false
        do { try await repair.relinkAsset(missingPhoto, to: [firstVideo]) } catch { rejected = true }
        try requireProject(rejected && repair.document == beforeWrongKind && !repair.isRelinkingAssets,
                           "Wrong-kind repair must leave every existing clip and caption unchanged")
        try await repair.relinkAsset(missingPhoto, to: [photo])
        try requireProject(repair.clips.map(\.url) == [photo, photo] && repair.clips.map(\.id) == missingDocument.clips.map(\.id) &&
                           repair.clips.map(\.duration) == missingDocument.clips.map(\.duration) && repair.captions == missingDocument.captions && repair.missingProjectAssets.isEmpty,
                           "Photo repair must preserve IDs, exact durations and captions while repairing repeated references")
        repair.undoEdit()
        try requireProject(repair.document == missingDocument && repair.missingProjectAssets.count == 1,
                           "Undo must restore the previous missing paths and exact creative edit")
        repair.redoEdit()
        try requireProject(repair.clips.allSatisfy { $0.url == photo } && repair.captions == missingDocument.captions && repair.missingProjectAssets.isEmpty,
                           "Redo must restore the repaired storage references")
        print("PASS: missing-photo detection, wrong-kind rejection, repeated-reference repair and exact undo/redo")

        let preflight = makeModel(recovery: root.appendingPathComponent("preflight-recovery.yingshu"), autosave: false)
        var preflightDocument = missingDocument
        // The deduplicated missing asset points at the first use, but only its second use carries words.
        preflightDocument.captions[0].clipID = preflightDocument.clips[1].id
        let preflightProject = root.appendingPathComponent("preflight.yingshu.json")
        let preflightOutput = root.appendingPathComponent("preflight-output", isDirectory: true)
        try FileManager.default.createDirectory(at: preflightOutput, withIntermediateDirectories: false)
        try write(preflightDocument, to: preflightProject)
        try preflight.applyDocument(from: preflightProject)
        try requireProject(preflight.missingProjectAssets.count == 1 && preflight.missingProjectAssets[0].clipID == preflight.clips[0].id &&
                           !preflight.captions.contains(where: { $0.clipID == preflight.clips[0].id }),
                           "Caption export preflight fixture must deduplicate the uncaptioned first use of the missing source")
        preflight.startCaptionImageExport(to: preflightOutput)
        try requireProject(preflight.isShowingMissingAssets && !preflight.isExporting && preflight.lastExportURL == nil &&
                           preflight.document == preflightDocument && (try FileManager.default.contentsOfDirectory(atPath: preflightOutput.path)).isEmpty,
                           "Caption-image export must block before starting when any captioned use of a deduplicated source is missing")
        print("PASS: caption-image preflight catches a missing shared source even when only its second use carries words")

        var missingVideo = videoDocument
        missingVideo.clips[0].url = root.appendingPathComponent("missing-video.mp4")
        missingVideo.clips[0].trimStart = 0.2; missingVideo.clips[0].duration = 0.6
        missingVideo.clips[0].timingLocked = true
        missingVideo.captions = [Caption(clipID: missingVideo.clips[0].id, start: 0.1, duration: 0.4, text: "我决定的原片位置。")]
        try write(missingVideo, to: missingProject)
        try repair.applyDocument(from: missingProject)
        guard let missingMotion = repair.missingProjectAssets.first else { throw StudioError.message("Missing video was not detected") }
        try await repair.relinkAsset(missingMotion, to: [secondVideo])
        try requireProject(repair.clips[0].id == missingVideo.clips[0].id && repair.clips[0].trimStart == 0.2 &&
                           repair.clips[0].duration == 0.6 && repair.clips[0].timingLocked == true && repair.captions == missingVideo.captions &&
                           (repair.player.currentItem?.asset as? AVURLAsset)?.url == secondVideo,
                           "Video repair must retain trim, duration, lock and caption IDs while refreshing playback")
        repair.undoEdit()
        try requireProject(repair.document == missingVideo, "Undo video repair changed the accepted timeline")
        print("PASS: video repair preserves clip/caption identity, exact trim and duration, timing lock and preview")

        guard let unavailableItem = repair.player.currentItem else { throw StudioError.message("Missing video did not create a preview item") }
        let playerFailureDeadline = ProcessInfo.processInfo.systemUptime + 3
        while unavailableItem.status != .failed && ProcessInfo.processInfo.systemUptime < playerFailureDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try requireProject(unavailableItem.status == .failed, "Missing video fixture did not actually fail in AVPlayer")
        let returnedSource = missingVideo.clips[0].url
        try FileManager.default.copyItem(at: secondVideo, to: returnedSource)
        try await repair.relinkAsset(missingMotion, to: [returnedSource])
        try requireProject(repair.player.currentItem != nil && repair.player.currentItem !== unavailableItem &&
                           (repair.player.currentItem?.asset as? AVURLAsset)?.url == returnedSource &&
                           repair.clips[0].id == missingVideo.clips[0].id && repair.captions == missingVideo.captions,
                           "Restoring the same source path must replace a failed AVPlayerItem without losing edits")
        print("PASS: same-path video repair rebuilds the failed preview item")

        let recheck = makeModel(recovery: root.appendingPathComponent("recheck-recovery.yingshu"), autosave: false)
        var recheckDocument = missingVideo
        recheckDocument.clips[0].url = root.appendingPathComponent("return-on-recheck.mp4")
        let recheckProject = root.appendingPathComponent("recheck.yingshu.json")
        try write(recheckDocument, to: recheckProject)
        try recheck.applyDocument(from: recheckProject)
        recheck.seek(to: 0.35)
        guard let failedBeforeRecheck = recheck.player.currentItem else { throw StudioError.message("Missing recheck video did not create a preview item") }
        let recheckFailureDeadline = ProcessInfo.processInfo.systemUptime + 3
        while failedBeforeRecheck.status != .failed && ProcessInfo.processInfo.systemUptime < recheckFailureDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try requireProject(failedBeforeRecheck.status == .failed && recheck.missingProjectAssets.count == 1,
                           "Recheck fixture must begin with a failed preview and a missing source")
        try FileManager.default.copyItem(at: secondVideo, to: recheckDocument.clips[0].url)
        recheck.refreshMissingProjectAssets()
        guard let restoredPreview = recheck.player.currentItem else { throw StudioError.message("Recheck removed the preview instead of refreshing it") }
        try requireProject(restoredPreview !== failedBeforeRecheck && recheck.missingProjectAssets.isEmpty && recheck.currentTime == 0.35,
                           "Recheck must refresh the returned source and retain the current timeline position")
        let previewReadyDeadline = ProcessInfo.processInfo.systemUptime + 3
        let expectedSourceTime = recheckDocument.clips[0].trimStart + 0.35
        while (restoredPreview.status != .readyToPlay || abs(recheck.player.currentTime().seconds - expectedSourceTime) > 0.04),
              ProcessInfo.processInfo.systemUptime < previewReadyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try requireProject(restoredPreview.status == .readyToPlay && abs(recheck.player.currentTime().seconds - expectedSourceTime) <= 0.04,
                           "Returned video must actually become playable at its previous trimmed position")
        for _ in 0..<3 { recheck.refreshMissingProjectAssets() }
        try requireProject(recheck.player.currentItem === restoredPreview && recheck.currentTime == 0.35 && recheck.document == recheckDocument &&
                           !recheck.hasUnsavedProjectChanges,
                           "Ordinary availability checks must reuse the playable video item without changing edits or position")
        print("PASS: rechecking a returned original rebuilds failed playback once and later checks preserve the decoder and playhead")

        let wave = root.appendingPathComponent("replacement.wav")
        try makeSilentWave(at: wave)
        var builtinMusic = sharedDocument
        builtinMusic.musicID = "breeze"; builtinMusic.customMusicURL = nil
        try write(builtinMusic, to: missingProject)
        try repair.applyDocument(from: missingProject)
        guard let missingBuiltin = repair.missingProjectAssets.first(where: { $0.kind == .music }) else {
            throw StudioError.message("The isolated directory must expose the absent built-in music resource")
        }
        try await repair.relinkAsset(missingBuiltin, to: [wave])
        try requireProject(repair.musicID == "custom" && repair.customMusicURL == wave && repair.selectedMusicURL == wave &&
                           repair.clips == builtinMusic.clips && repair.captions == builtinMusic.captions && repair.missingProjectAssets.isEmpty,
                           "Repairing an unavailable built-in track must select the verified replacement")
        repair.undoEdit()
        try requireProject(repair.document == builtinMusic && repair.missingProjectAssets.contains(where: { $0.kind == .music }),
                           "Undo must restore the built-in selection and its missing-asset state")
        print("PASS: missing built-in music can use a verified custom replacement and undo restores the original selection")

        var missingMusic = sharedDocument
        missingMusic.musicID = "custom"
        missingMusic.customMusicURL = root.appendingPathComponent("missing-music.wav")
        missingMusic.musicVolume = 0.27
        try write(missingMusic, to: missingProject)
        try repair.applyDocument(from: missingProject)
        guard let musicAsset = repair.missingProjectAssets.first(where: { $0.kind == .music }) else { throw StudioError.message("Missing music was not detected") }
        let beforeMusic = repair.document
        rejected = false
        do { try await repair.relinkAsset(musicAsset, to: [photo]) } catch { rejected = true }
        try requireProject(rejected && repair.document == beforeMusic, "Invalid music replacement changed the project")
        try await repair.relinkAsset(musicAsset, to: [wave])
        try requireProject(repair.customMusicURL == wave && repair.selectedMusicURL == wave && repair.musicVolume == 0.27 &&
                           repair.clips == missingMusic.clips && repair.captions == missingMusic.captions && repair.missingProjectAssets.isEmpty,
                           "Music repair must replace only its missing storage reference")
        repair.undoEdit()
        try requireProject(repair.document == missingMusic, "Undo music repair changed project content")
        print("PASS: missing music rejects non-audio, restores playable audio and retains its mix and timeline")

        let liveID = UUID().uuidString
        let liveStill = root.appendingPathComponent("replacement-live.jpg")
        let liveMotion = root.appendingPathComponent("replacement-live.mov")
        try makePhoto(at: liveStill, liveID: liveID)
        try await makeVideo(at: liveMotion, red: 0.5, liveID: liveID)
        let validPair = await LivePhotoImporter.systemValidates(stillURL: liveStill, movieURL: liveMotion)
        try requireProject(validPair, "The system rejected the generated Live Photo pair")
        var liveDocument = sharedDocument
        var liveClip = try await MediaEngine.inspect(url: liveMotion)
        liveClip.url = root.appendingPathComponent("missing-live.mov")
        liveClip.livePhotoStillURL = root.appendingPathComponent("missing-live.jpg")
        liveClip.livePhotoAssetID = liveID
        liveClip.trimStart = 0.25; liveClip.duration = 1.25; liveClip.timingLocked = true
        liveDocument.clips = [liveClip]
        liveDocument.captions = [Caption(clipID: liveClip.id, start: 0.2, duration: 0.8, text: "这张实况的感想和时间都保留。", style: .companion)]
        try write(liveDocument, to: missingProject)
        try repair.applyDocument(from: missingProject)
        guard let liveAsset = repair.missingProjectAssets.first else { throw StudioError.message("Missing Live Photo was not detected") }
        try requireProject(liveAsset.kind == .livePhoto && repair.missingProjectAssets.count == 1,
                           "A missing Live Photo pair must appear as one repairable logical clip")
        rejected = false
        do { try await repair.relinkAsset(liveAsset, to: [liveStill]) } catch { rejected = true }
        try requireProject(rejected && repair.document == liveDocument, "An incomplete Live Photo repair must keep the original project intact")
        try await repair.relinkAsset(liveAsset, to: [liveMotion, liveStill])
        let repairedLive = repair.clips[0]
        try requireProject(repairedLive.id == liveClip.id && repairedLive.url == liveMotion && repairedLive.livePhotoStillURL == liveStill &&
                           repairedLive.livePhotoAssetID == liveID && repairedLive.trimStart == liveClip.trimStart && repairedLive.duration == liveClip.duration &&
                           repairedLive.timingLocked == true && repair.captions == liveDocument.captions && repair.missingProjectAssets.isEmpty,
                           "Live Photo repair must retain the logical clip and all creative edits while restoring both original resources")
        repair.undoEdit()
        try requireProject(repair.document == liveDocument, "Undo Live Photo repair must restore both missing references and exact captions")
        print("PASS: verified Live Photo pair repair, incomplete-pair rejection and exact original caption/trim recovery")

        let keyboard = makeModel(recovery: root.appendingPathComponent("keyboard-recovery.yingshu"), autosave: false)
        keyboard.clips = [clip]; keyboard.captions = [caption]; keyboard.selectedClipID = clip.id
        keyboard.musicID = nil; keyboard.automaticEditEnabled = false; keyboard.currentTime = 1
        let controls: [NSResponder] = [NSButton(), NSSlider(), NSSegmentedControl(), NSPopUpButton(),
                                       NSTextField(), NSSearchField(), NSTableView(), NSTextView()]
        let controlParent = NSSlider(), controlChild = NSView()
        controlParent.addSubview(controlChild)
        let shortcutKeys: [UInt16] = [15, 49, 123, 124, 51, 117]
        let keyboardBefore = keyboard.document
        for responder in controls + [controlChild] {
            for code in shortcutKeys {
                let event = try keyEvent(code: code)
                try requireProject(keyboard.handleEditorKeyDown(event, firstResponder: responder) === event,
                                   "Editor monitor consumed a native control or text input key")
            }
        }
        try requireProject(keyboard.document == keyboardBefore && keyboard.currentTime == 1 && !keyboard.isPlaying && !keyboard.isTranscribing,
                           "Native control key handling must not edit or play the project")
        let canvas = NSView()
        let space = try keyEvent(code: 49)
        try requireProject(keyboard.handleEditorKeyDown(space, firstResponder: canvas) == nil && keyboard.isPlaying,
                           "Space on the editing canvas must retain normal playback behavior")
        keyboard.pause()
        let right = try keyEvent(code: 124)
        try requireProject(keyboard.handleEditorKeyDown(right, firstResponder: canvas) == nil && keyboard.currentTime == 4,
                           "Right arrow on the editing canvas must retain its three-second seek")
        let left = try keyEvent(code: 123)
        try requireProject(keyboard.handleEditorKeyDown(left, firstResponder: canvas) == nil && keyboard.currentTime == 1,
                           "Left arrow on the editing canvas must retain its three-second seek")
        let record = try keyEvent(code: 15)
        try requireProject(keyboard.handleEditorKeyDown(record, firstResponder: canvas) == nil && keyboard.isTranscribing,
                           "R on the editing canvas must retain normal recording preparation")
        keyboard.cancelRecordingPreparation()
        let commandSpace = try keyEvent(code: 49, modifiers: .command)
        try requireProject(keyboard.handleEditorKeyDown(commandSpace, firstResponder: canvas) === commandSpace &&
                           keyboard.handleEditorKeyDown(space, firstResponder: canvas, isModal: true) === space,
                           "Modified shortcuts and modal windows must retain native event handling")
        print("PASS: native controls and text editors keep their keys; canvas R, Space and arrow shortcuts remain active")

        let preservedBytes = Data("original source or project data must remain intact".utf8)
        let completedVideoBytes = Data("already verified MP4; sidecar issues must not invalidate it".utf8)
        for role in ["clip", "live-photo-still", "custom-music", "downloaded-music", "project", "recovery"] {
            for link in ["same-path", "symlink", "hardlink"] {
                let directory = root.appendingPathComponent("credit-\(role)-\(link)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let output = directory.appendingPathComponent("finished.mp4")
                let credit = directory.appendingPathComponent("finished.music-credit.txt")
                let original = link == "same-path" ? credit : directory.appendingPathComponent("protected-original.bin")
                var creditDocument = sharedDocument
                creditDocument.captions = []; creditDocument.musicID = nil; creditDocument.automaticEditEnabled = false
                switch role {
                case "clip": creditDocument.clips[0].url = original
                case "live-photo-still":
                    creditDocument.clips = [videoClip]
                    creditDocument.clips[0].livePhotoStillURL = original
                case "custom-music": creditDocument.customMusicURL = original
                case "downloaded-music":
                    creditDocument.downloadedMusic = [DownloadedMusic(id: "credit-fixture", name: "本机保护曲目", artist: "测试",
                        localURL: original, sourceURL: URL(string: "https://example.invalid/source")!, license: "CC BY 4.0",
                        licenseURL: URL(string: "https://example.invalid/license")!, attribution: "测试署名")]
                default: break
                }
                try preservedBytes.write(to: original)
                let documentPath = role == "project" ? original : directory.appendingPathComponent("named.yingshu.json")
                try write(creditDocument, to: documentPath)
                let creditModel = makeModel(recovery: role == "recovery" ? original : directory.appendingPathComponent("recovery.yingshu"), autosave: false)
                try creditModel.applyDocument(from: documentPath)
                if link == "symlink" { try FileManager.default.createSymbolicLink(at: credit, withDestinationURL: original) }
                else if link == "hardlink" { try FileManager.default.linkItem(at: original, to: credit) }
                try completedVideoBytes.write(to: output)
                let beforeOriginal = try Data(contentsOf: original)
                let attributionWarning = creditModel.saveMusicCredit("需要保留的配乐署名", beside: output)
                let cleanupWarning = creditModel.saveMusicCredit(nil, beside: output)
                try requireProject(attributionWarning.contains("复制署名") && cleanupWarning.contains("保留原文件") &&
                                   (try Data(contentsOf: original)) == beforeOriginal && (try Data(contentsOf: credit)) == beforeOriginal &&
                                   (try Data(contentsOf: output)) == completedVideoBytes && creditModel.errorMessage == nil,
                                   "Music credit write/cleanup must protect \(role) through \(link) without invalidating the completed video")
            }
        }
        let ordinaryCredit = makeModel(recovery: root.appendingPathComponent("ordinary-credit-recovery.yingshu"), autosave: false)
        ordinaryCredit.musicID = nil
        let ordinaryOutput = root.appendingPathComponent("ordinary-finished.mp4")
        let ordinarySidecar = ordinaryOutput.deletingPathExtension().appendingPathExtension("music-credit.txt")
        try completedVideoBytes.write(to: ordinaryOutput)
        try requireProject(ordinaryCredit.saveMusicCredit("可以正常保存的署名", beside: ordinaryOutput).contains("另存为文本") &&
                           (try String(contentsOf: ordinarySidecar, encoding: .utf8)).contains("可以正常保存的署名"),
                           "A nonconflicting music credit sidecar must still be written normally")
        try requireProject(ordinaryCredit.saveMusicCredit(nil, beside: ordinaryOutput).isEmpty && !FileManager.default.fileExists(atPath: ordinarySidecar.path) &&
                           (try Data(contentsOf: ordinaryOutput)) == completedVideoBytes,
                           "A nonconflicting stale sidecar must still be removed without touching the video")
        try FileManager.default.createDirectory(at: ordinarySidecar, withIntermediateDirectories: false)
        let existingFolderContents = ordinarySidecar.appendingPathComponent("keep.txt")
        try preservedBytes.write(to: existingFolderContents)
        try requireProject(ordinaryCredit.saveMusicCredit("文件夹不能作为署名文件", beside: ordinaryOutput).contains("已保留其中内容") &&
                           ordinaryCredit.saveMusicCredit(nil, beside: ordinaryOutput).contains("已保留其中内容") &&
                           (try Data(contentsOf: existingFolderContents)) == preservedBytes &&
                           (try Data(contentsOf: ordinaryOutput)) == completedVideoBytes,
                           "Neither music-credit write failure nor stale cleanup may recursively delete an existing folder")
        print("PASS: music credit writes and cleanup protect sources, Live Photo stills, music, projects and recovery across paths and links")

        for item in models { await item.prepareToTerminate() }
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        try requireProject(!paths.contains(where: { $0.hasPrefix("Tests/") || $0.hasPrefix("Resources/") }),
                           "Fixtures unexpectedly depend on or write through repository-relative paths")
        print("PASS: all generated media, projects and recovery copies are isolated in the disposable directory")
    }

    private static func write(_ document: ProjectDocument, to url: URL) throws {
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }

    private static func keyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: code == 15 ? "r" : " ",
            charactersIgnoringModifiers: code == 15 ? "r" : " ", isARepeat: false, keyCode: code) else {
            throw StudioError.message("Cannot create a local keyboard regression event")
        }
        return event
    }

    private static func requireSaved(_ state: RecoverySaveState, _ message: String) throws {
        guard case .saved(let date) = state, date.timeIntervalSince1970.isFinite else { throw StudioError.message(message) }
    }

    @MainActor private static func waitForRecovery(_ model: AppModel) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while model.recoverySaveState == .pending, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try requireProject(model.recoverySaveState != .pending, "Recovery write did not finish within its bounded deadline")
    }

    private static func makePhoto(at url: URL, liveID: String? = nil) throws {
        guard let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudioError.message("Cannot create disposable photo pixels")
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let type = liveID == nil ? UTType.png : UTType.jpeg
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw StudioError.message("Cannot create disposable photo destination")
        }
        let metadata: [String: Any] = liveID.map { [kCGImagePropertyMakerAppleDictionary as String: ["17": $0]] } ?? [:]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        try requireProject(CGImageDestinationFinalize(destination), "Cannot finish disposable photo")
    }

    private static func makeVideo(at url: URL, red: CGFloat, liveID: String? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: liveID == nil ? .mp4 : .mov)
        if let liveID {
            let identifier = AVMutableMetadataItem(); identifier.identifier = .quickTimeMetadataContentIdentifier
            identifier.value = liveID as NSString; identifier.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [identifier]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if liveID != nil {
            var description: CMMetadataFormatDescription?
            let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
            try requireProject(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description) == noErr,
                "Cannot create disposable Live Photo metadata")
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
            writer.add(metadataInput)
        }
        try requireProject(writer.startWriting(), "Cannot start disposable video writer")
        writer.startSession(atSourceTime: .zero)
        if let metadataAdaptor {
            let stillTime = AVMutableMetadataItem(); stillTime.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
            stillTime.value = NSNumber(value: Int8(0)); stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
            let group = AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(start: CMTime(value: 30, timescale: 30), duration: CMTime(value: 1, timescale: 30)))
            try requireProject(metadataAdaptor.append(group), "Cannot append disposable Live Photo metadata")
            metadataAdaptor.assetWriterInput.markAsFinished()
        }
        let frameCount = liveID == nil ? 30 : 60
        for frame in 0..<frameCount {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !input.isReadyForMoreMediaData {
                try requireProject(writer.status == .writing && ProcessInfo.processInfo.systemUptime < deadline, "Disposable video writer stalled")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            try requireProject(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
                "Cannot create disposable video frame")
            guard let buffer else { throw StudioError.message("Disposable video frame missing") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 160, height: 90, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw StudioError.message("Cannot draw disposable video frame")
            }
            context.setFillColor(CGColor(red: red, green: CGFloat(frame) / 30, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try requireProject(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Cannot append disposable video frame")
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        try requireProject(writer.status == .completed, "Cannot finish disposable video: \(writer.error?.localizedDescription ?? "unknown")")
    }

    private static func makeSilentWave(at url: URL) throws {
        let sampleRate: UInt32 = 8_000, payloadSize = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36) + payloadSize); data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16)); data.append(contentsOf: "data".utf8); append(payloadSize)
        data.append(Data(repeating: 0, count: Int(payloadSize)))
        try data.write(to: url, options: .atomic)
    }
}
