import AppKit
import Combine
import Foundation

@MainActor final class FakeSpeechInput: SpeechInput {
    let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = "这一刻，想让它停留久一点。"
    var status = "测试语音"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    var failStart = false
    func start() async throws {
        if failStart { throw StudioError.message("测试启动失败") }
        isRecording = true; updates.send()
    }
    func stop() async -> String {
        isRecording = false; updates.send()
        try? await Task.sleep(nanoseconds: 120_000_000)
        return transcript
    }
    func cancel() { isRecording = false; updates.send() }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String { transcript }
}

@main struct ModelChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let a = MediaClip(url: root.appendingPathComponent("Resources/demo-coast.png"), name: "海", kind: .image, duration: 4, sourceDuration: 30)
        let b = MediaClip(url: root.appendingPathComponent("Resources/demo-hills.png"), name: "山", kind: .image, duration: 5, sourceDuration: 30)
        let moments = [PlaybackMoment(audioTime: 0, clipID: a.id, offset: 0),
                       PlaybackMoment(audioTime: 2, clipID: a.id, offset: 2),
                       PlaybackMoment(audioTime: 4, clipID: a.id, offset: 2), // picture paused for two audio seconds
                       PlaybackMoment(audioTime: 6, clipID: b.id, offset: 0),
                       PlaybackMoment(audioTime: 8, clipID: b.id, offset: 2)]
        let words = [DictationWord(text: "海边的风。", timestamp: 0.5, duration: 1),
                     DictationWord(text: "停下来看看。", timestamp: 3, duration: 0.8),
                     DictationWord(text: "山里的光很温柔。", timestamp: 6.5, duration: 1)]
        let aligned = DictationAlignment.captions(words: words, moments: moments, clips: [a,b], style: .note)
        precondition(aligned.count == 3 && aligned[0].clipID == a.id && aligned[1].clipID == a.id && aligned[2].clipID == b.id)
        precondition(DictationAlignment.location(at: 3, moments: moments)?.offset == 2, "Paused video stays aligned to audio time")
        precondition(DictationAlignment.location(at: 7, moments: moments)?.offset == 1, "Interpolate moving picture time")
        precondition(aligned.map(\.text).joined() == words.map(\.text).joined(), "Cross-clip alignment preserves all text")
        precondition(aligned.allSatisfy { c in [a,b].contains { $0.id == c.clipID && c.start >= 0 && c.start + c.duration <= $0.duration + 0.001 } })
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        model.automaticEditEnabled = false
        model.clips = [a, b]
        let caption = model.makeCaption(clip: a, offset: 3.9, spokenDuration: 8, text: "这是我的感想")
        precondition(caption.start == 0 && caption.duration == 4, "Late speech stays inside its anchor clip")
        model.captions = [caption]
        model.moveClip(a.id, by: 1)
        precondition(model.clips[1].id == a.id && model.captions[0].clipID == a.id)
        precondition(model.clips.startTime(of: caption.clipID) + caption.start == 5)
        precondition(model.clips.location(at: 5)?.clip.id == a.id, "Exact boundary selects next clip")
        var shorter = a; shorter.duration = 1
        model.updateClip(shorter)
        precondition(model.captions[0].duration == 1 && model.captions[0].start == 0)
        model.commitSpokenCaption(Caption(clipID: a.id, start: 0.2, duration: 0.6, text: "新的感想", style: caption.style))
        precondition(model.captions.count == 1 && model.captions[0].text.contains("这是我的感想") && model.captions[0].text.contains("新的感想"), "Overlapping dictation joins a card without losing words")
        let ordering = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        var longClip = a; longClip.duration = 8; ordering.clips = [longClip]
        ordering.commitSpokenCaption(Caption(clipID: a.id, start: 5.8, duration: 2.2, text: "先说的短句。"))
        ordering.commitSpokenCaption(Caption(clipID: a.id, start: 4.5, duration: 3.5, text: "后说的长句因为阅读需要而向前移动，也要保持说话顺序。"))
        precondition(ordering.captions[0].text.hasPrefix("先说的短句。"), "Readability adjustments cannot reverse speech")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingShu-ModelChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let valid = temporary.appendingPathComponent("valid.json")
        try model.writeDocument(to: valid)
        let restored = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        try restored.applyDocument(from: valid)
        precondition(restored.clips == model.clips && restored.captions == model.captions)
        precondition(!restored.automaticEditEnabled && restored.clips.first(where: { $0.id == a.id })?.timingLocked == true, "Auto toggle and manual timing lock survive project roundtrip")
        var bad = model.document; bad.title = "invalid must not replace project"
        bad.captions[0].clipID = UUID()
        let invalid = temporary.appendingPathComponent("invalid.json")
        try JSONEncoder().encode(bad).write(to: invalid)
        do { try restored.applyDocument(from: invalid); preconditionFailure("Invalid project accepted") }
        catch { precondition(restored.title == model.title && restored.clips == model.clips) }
        restored.removeClip(a.id)
        precondition(restored.captions.isEmpty && restored.clips.count == 1)
        restored.undoEdit()
        precondition(restored.clips.count == 2 && restored.captions.count == 1, "Undo restores removed media and its text")
        restored.redoEdit()
        precondition(restored.clips.count == 1 && restored.captions.isEmpty)
        restored.undoEdit(); restored.setProjectTitle("新的标题")
        precondition(restored.redoCount == 0, "Metadata edit invalidates obsolete redo branch")
        restored.setVideoFormat(.portrait); restored.undoEdit()
        precondition(restored.title == "新的标题" && restored.format == .landscape, "Undo format preserves title")
        restored.setMusicSelection(nil); restored.undoEdit()
        precondition(restored.musicID == model.musicID)
        restored.currentTime = 2; restored.isTranscribing = true; restored.seek(to: 0)
        precondition(restored.currentTime == 2, "Cannot seek during recording startup/finalization")
        restored.isTranscribing = false
        let rapid = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false); rapid.clips = [a]
        rapid.toggleRecording(); rapid.toggleRecording()
        precondition(rapid.isTranscribing && !rapid.isPlaying, "Recording startup locks synchronously")
        await rapid.prepareToTerminate() // Cancels before permission request begins.
        precondition(!rapid.speech.isRecording && !rapid.isTranscribing)

        let fake = FakeSpeechInput()
        let paused = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, speechInput: fake)
        paused.clips = [a,b]; paused.seek(to: 2.8); paused.play(); paused.toggleRecording()
        for _ in 0..<50 { if fake.isRecording { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(fake.isRecording && !paused.isPlaying && !paused.isTranscribing)
        let frozenTime = paused.currentTime
        try await Task.sleep(nanoseconds: 220_000_000)
        paused.togglePlayback(); paused.seek(to: 6)
        precondition(paused.currentTime == frozenTime && !paused.isPlaying, "Recording freezes current picture and blocks playback/seek")
        await paused.finishRecording()
        precondition(paused.isPlaying && paused.currentTime == frozenTime, "Finish resumes from the exact paused location")
        precondition(paused.captions.count == 1 && paused.captions[0].clipID == a.id && paused.captions[0].text == fake.transcript)
        paused.pause()
        fake.transcript = ""; paused.toggleRecording()
        for _ in 0..<50 { if fake.isRecording { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await paused.finishRecording()
        precondition(paused.isPlaying && paused.captions.count == 1, "Empty speech still resumes and adds no empty card")
        paused.pause(); fake.failStart = true; paused.play(); paused.toggleRecording()
        for _ in 0..<50 { if !paused.isTranscribing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(paused.isPlaying && paused.errorMessage != nil, "Start failure restores prior playing state")
        paused.pause(); fake.failStart = false; fake.transcript = "关掉应用也不丢这句话。"; paused.toggleRecording()
        for _ in 0..<50 { if fake.isRecording { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await paused.prepareToTerminate()
        precondition(!paused.isPlaying && paused.captions.contains { $0.text.contains(fake.transcript) }, "Quit finalizes words without restarting video")

        let automatic = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        automatic.clips = [a,b]; automatic.musicID = nil
        automatic.arrangeAutomatically()
        precondition(automatic.isAutoEditing && !automatic.canEditStructure, "Auto plan locks edits immediately")
        let arranged = await automatic.ensureAutomaticEdit()
        precondition(arranged && !automatic.isAutoEditing && automatic.clips.map(\.id) == [a.id,b.id])
        precondition(automatic.autoEditSummary.contains("画面分析完成"))
        var locked = automatic.clips[0]; locked.duration = 2.25; automatic.updateClip(locked)
        automatic.captions.append(Caption(clipID: b.id, start: 0, duration: 1, text: "山里的风让我想起了很多很多没有说完的事情，这一段需要多停留。"))
        let replanned = await automatic.ensureAutomaticEdit()
        precondition(replanned && automatic.clips[0].duration == 2.25 && automatic.clips[0].timingLocked == true)
        precondition(automatic.captions[0].duration > 4, "Export preparation notices new captions and allows reading time")
        automatic.undoEdit()
        precondition(automatic.clips[0].timingLocked == true, "Undo an automatic plan preserves prior manual lock")
        let acceptedClips = automatic.clips, acceptedCaptions = automatic.captions
        let accepted = await automatic.ensureAutomaticEdit()
        precondition(accepted && automatic.clips == acceptedClips && automatic.captions == acceptedCaptions,
                     "Export preparation must respect an undone automatic edit")
        let changingMusic = temporary.appendingPathComponent("changing.wav")
        try Data(contentsOf: root.appendingPathComponent("Resources/breeze.wav")).write(to: changingMusic)
        automatic.customMusicURL = changingMusic; automatic.musicID = "custom"
        let withMusic = await automatic.ensureAutomaticEdit()
        precondition(withMusic && !automatic.autoEditSummary.contains("暂时无法分析"))
        try Data("same path, different file contents".utf8).write(to: changingMusic, options: .atomic)
        let replacedMusic = await automatic.ensureAutomaticEdit()
        precondition(replacedMusic && automatic.autoEditSummary.contains("暂时无法分析"),
                     "Replacing music at the same path invalidates the cached plan")

        let sequenced = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        sequenced.automaticEditEnabled = false
        var early = a; early.capturedAt = Date(timeIntervalSince1970: 1_700_000_000); early.importOrder = 1
        var late = b; late.capturedAt = Date(timeIntervalSince1970: 1_700_000_060); late.importOrder = 0
        sequenced.clips = [late,early]
        let pinned = Caption(clipID: late.id, start: 1, duration: 2, text: "感想跟着这个画面走。")
        sequenced.captions = [pinned]; sequenced.seek(to: 1.5)
        sequenced.setOrderMode(.chronological)
        precondition(sequenced.isOrdering && !sequenced.canEditStructure)
        let sorted = await sequenced.waitForOrdering()
        precondition(sorted && sequenced.clips.map(\.id) == [early.id,late.id] && sequenced.captions == [pinned])
        precondition(abs(sequenced.currentTime - (early.duration + 1.5)) < 0.001, "Sorting preserves the actual selected picture and offset")
        sequenced.undoEdit()
        precondition(sequenced.clips.map(\.id) == [late.id,early.id], "Undo restores the exact pre-sort sequence")
        sequenced.redoEdit()
        precondition(sequenced.clips.map(\.id) == [early.id,late.id])
        sequenced.moveClip(early.id, by: 1)
        precondition(sequenced.orderMode == .manual, "Manual movement disables automatic reordering on import")
        let sortedDocument = temporary.appendingPathComponent("sorted-project.json")
        try sequenced.writeDocument(to: sortedDocument)
        let reopened = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        try reopened.applyDocument(from: sortedDocument)
        precondition(reopened.orderMode == .manual && reopened.clips == sequenced.clips && !reopened.isOrdering)
        sequenced.setOrderMode(.story); sequenced.cancelOrdering()
        let cancelledOrder = await sequenced.waitForOrdering()
        precondition(!cancelledOrder && sequenced.orderMode == .manual && sequenced.clips.map(\.id) == [late.id,early.id], "Cancel applies neither partial order nor selected mode")
        var legacy = sequenced.document; legacy.orderMode = nil
        try JSONEncoder().encode(legacy).write(to: sortedDocument, options: .atomic)
        try reopened.applyDocument(from: sortedDocument)
        precondition(reopened.orderMode == .manual && reopened.clips == legacy.clips, "Legacy projects open in preserved manual order")
        legacy.automaticEditEnabled = nil
        try JSONEncoder().encode(legacy).write(to: sortedDocument, options: .atomic)
        try reopened.applyDocument(from: sortedDocument)
        precondition(!reopened.automaticEditEnabled, "Old projects without auto-edit settings must retain their original timing")
        let chained = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        chained.musicID = nil; chained.clips = [late,early]; chained.currentTime = chained.totalDuration
        chained.setOrderMode(.chronological)
        _ = await chained.waitForOrdering(); _ = await chained.ensureAutomaticEdit()
        precondition(chained.currentClip?.id == early.id, "The former last frame remains on its clip after sorting")
        chained.undoEdit()
        precondition(chained.clips == [late,early], "One undo restores the whole sort plus its automatic timing changes")
        print("PASS: alignment; editing; recording; auto-edit invalidation; sorting/anchors/undo/cancel/persistence and legacy order")
    }
}
