import AppKit
import Combine
import Foundation

/// Injects deterministic partial/final results without accessing Speech or a microphone.
@MainActor private final class EditingSpeech: SpeechInput {
    let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var status = "测试语音"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    var partialText = "海便的风"
    var finalText = "海便的风，让这一刻慢下来。"
    var starts = 0
    var stops = 0
    var startDelay: UInt64 = 0
    func start() async throws {
        if startDelay > 0 { try await Task.sleep(nanoseconds: startDelay) }
        starts += 1; isRecording = true; transcript = partialText
        wordSegments = partialText.isEmpty ? [] : [SpeechSegment(text: partialText, timestamp: 0, duration: 0.6)]
        segments = wordSegments; updates.send()
    }
    func stop() async -> String {
        stops += 1; isRecording = false; updates.send()
        try? await Task.sleep(nanoseconds: 90_000_000)
        transcript = finalText
        wordSegments = finalText.isEmpty ? [] : [SpeechSegment(text: finalText, timestamp: 0, duration: 0.9)]
        segments = wordSegments; updates.send()
        return finalText
    }
    func cancel() { isRecording = false; updates.send() }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String { finalText }
    func emitLate(_ text: String) {
        transcript = text; updates.send(); onUnexpectedStop?(text)
    }
    func endNaturally() {
        isRecording = false; transcript = finalText
        wordSegments = finalText.isEmpty ? [] : [SpeechSegment(text: finalText, timestamp: 0, duration: 0.9)]
        segments = wordSegments; updates.send(); onUnexpectedStop?(finalText)
    }
}

@main struct CaptionEditingChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let clip = MediaClip(url: root.appendingPathComponent("Resources/demo-coast.png"), name: "海边", kind: .image,
                             duration: 8, sourceDuration: 30, timingLocked: true)
        let original = Caption(clipID: clip.id, start: 0.4, duration: 5.2, text: "海便的风很温柔。", style: .note)
        let speech = EditingSpeech()
        let model = makeModel(clip: clip, speech: speech)
        model.captions = [original]; model.currentTime = 1.2
        model.play()
        model.beginCaptionEditing(original.id)
        try await waitUntil { model.editingCaptionID == original.id && !model.isPreparingCaptionEdit }
        precondition(model.editingCaptionID == original.id && model.captionEditDraft == original.text && !model.isPlaying)
        precondition(!model.canEditStructure, "Editing must block structural actions")
        let pausedAt = model.currentTime
        model.togglePlayback(); model.seek(to: 7); model.toggleRecording()
        precondition(!model.isPlaying && model.currentTime == pausedAt && speech.starts == 0, "Playback, seeking, and new recordings cannot race the draft")
        model.captionEditDraft = "海边的风很温柔。"
        precondition(model.captions == [original], "Typing is an uncommitted draft")
        model.saveCaptionEditing()
        let corrected = model.captions[0]
        precondition(corrected.text == "海边的风很温柔。" && unchangedPlacement(corrected, original))
        precondition(model.editingCaptionID == nil && model.isPlaying)
        model.undoEdit()
        precondition(model.captions == [original], "Undo restores the original words and all placement fields")
        model.redoEdit()
        precondition(model.captions == [corrected])
        print("PASS paused editing, text-only save, playback/recording protection, undo/redo")

        model.pause()
        let history = model.undoCount
        model.beginCaptionEditing(corrected.id)
        try await waitUntil { model.editingCaptionID == corrected.id && !model.isPreparingCaptionEdit }
        model.captionEditDraft = "取消时不应保存这句。"
        model.cancelCaptionEditing()
        precondition(model.captions == [corrected] && !model.isPlaying && model.undoCount == history)
        model.play(); model.beginCaptionEditing(corrected.id)
        try await waitUntil { model.editingCaptionID == corrected.id && !model.isPreparingCaptionEdit }
        model.cancelCaptionEditing()
        precondition(model.isPlaying && model.captions == [corrected])
        model.beginCaptionEditing(corrected.id)
        try await waitUntil { model.editingCaptionID == corrected.id && !model.isPreparingCaptionEdit }
        model.captionEditDraft = " \n\t "
        model.saveCaptionEditing()
        precondition(model.captions == [corrected] && model.editingCaptionID == corrected.id && !model.isPlaying,
                     "Blank text cannot silently hide or delete the card")
        precondition(model.captionEditIssue != nil && model.errorMessage == nil,
                     "A blank draft needs inline feedback without presenting a second modal")
        model.cancelCaptionEditing()
        let noOpHistory = model.undoCount
        model.beginCaptionEditing(corrected.id)
        try await waitUntil { model.editingCaptionID == corrected.id && !model.isPreparingCaptionEdit }
        model.saveCaptionEditing()
        precondition(model.undoCount == noOpHistory, "Saving unchanged words should not add a false undo step")
        let unknown = UUID()
        model.beginCaptionEditing(unknown)
        precondition(model.editingCaptionID == nil, "A stale rendered identifier cannot open another caption")
        print("PASS cancel/resume policy, blank protection, no-op history, stale identifiers")

        let autoSpeech = EditingSpeech()
        let auto = makeModel(clip: clip, speech: autoSpeech)
        auto.clips[0].timingLocked = nil
        auto.musicID = "none"; auto.automaticEditEnabled = true; auto.captions = [original]
        let initiallyPlanned = await auto.ensureAutomaticEdit()
        precondition(initiallyPlanned)
        auto.beginCaptionEditing(original.id)
        try await waitUntil { auto.editingCaptionID == original.id && !auto.isPreparingCaptionEdit }
        auto.captionEditDraft = auto.captionEditDraft.replacingOccurrences(of: "海便", with: "海边")
        auto.saveCaptionEditing()
        let acceptedClips = auto.clips, acceptedCaptions = auto.captions, acceptedHistory = auto.undoCount
        let preservedPlan = await auto.ensureAutomaticEdit()
        precondition(preservedPlan && auto.clips == acceptedClips && auto.captions == acceptedCaptions
                     && auto.undoCount == acceptedHistory,
                     "Export preparation must accept a text correction without moving cards, retiming clips, or adding an automatic-edit undo step")
        print("PASS text correction preserves the accepted timeline when automatic editing is enabled")

        let liveSpeech = EditingSpeech()
        let live = makeModel(clip: clip, speech: liveSpeech)
        live.currentTime = 2; live.play(); live.toggleRecording()
        try await waitUntil { liveSpeech.isRecording && !live.isTranscribing }
        let frozen = live.currentTime
        live.beginLiveCaptionEditing()
        precondition(live.isPreparingCaptionEdit)
        live.beginLiveCaptionEditing()
        try await waitUntil { live.editingCaptionID != nil && !live.isPreparingCaptionEdit }
        precondition(liveSpeech.stops == 1 && !liveSpeech.isRecording && !live.isPlaying)
        precondition(live.captionEditDraft == liveSpeech.finalText, "The final tail must arrive before the editor draft is created")
        precondition(live.currentTime == frozen, "Opening the live editor keeps the recorded picture paused")
        let liveID = live.editingCaptionID!
        let finalized = live.captions.first { $0.id == liveID }!
        live.captionEditDraft = live.captionEditDraft.replacingOccurrences(of: "海便", with: "海边")
        liveSpeech.emitLate("不应覆盖更正的迟到尾巴")
        precondition(live.editingCaptionID == liveID && live.captionEditDraft.contains("海边") && live.captions == [finalized])
        live.saveCaptionEditing()
        let liveCorrected = live.captions[0]
        precondition(liveCorrected.text == "海边的风，让这一刻慢下来。" && unchangedPlacement(liveCorrected, finalized))
        precondition(live.isPlaying)
        liveSpeech.emitLate("第二个迟到回调")
        precondition(live.captions == [liveCorrected], "Late speech completion cannot append or overwrite edited text")
        print("PASS live stop exactly once, final tail, stable ID, same frame, late-callback protection")

        let mergingSpeech = EditingSpeech()
        let merging = makeModel(clip: clip, speech: mergingSpeech)
        let previous = Caption(clipID: clip.id, start: 0, duration: 5, text: "上一句保留。", style: .sticker)
        merging.captions = [previous]; merging.selectedCaptionID = previous.id; merging.currentTime = 1
        merging.play(); merging.toggleRecording()
        try await waitUntil { mergingSpeech.isRecording && !merging.isTranscribing }
        merging.beginLiveCaptionEditing()
        try await waitUntil { merging.editingCaptionID != nil && !merging.isPreparingCaptionEdit }
        precondition(merging.editingCaptionID == previous.id && merging.captionEditDraft.contains(previous.text)
                     && merging.captionEditDraft.contains(mergingSpeech.finalText), "Live editing must target the finalized merged card, not the temporary live layer")
        merging.cancelCaptionEditing()

        let silentSpeech = EditingSpeech(); silentSpeech.partialText = ""; silentSpeech.finalText = ""
        let silent = makeModel(clip: clip, speech: silentSpeech)
        silent.captions = [previous]; silent.selectedCaptionID = previous.id; silent.play(); silent.toggleRecording()
        try await waitUntil { silentSpeech.isRecording && !silent.isTranscribing }
        silent.beginLiveCaptionEditing()
        try await waitUntil { !silent.isPreparingCaptionEdit && !silent.isTranscribing && !silentSpeech.isRecording }
        precondition(silent.editingCaptionID == nil && silent.captions == [previous], "No recognized words must not open an unrelated old selected caption")

        let naturalSpeech = EditingSpeech()
        let natural = makeModel(clip: clip, speech: naturalSpeech)
        natural.play(); natural.toggleRecording()
        try await waitUntil { naturalSpeech.isRecording && !natural.isTranscribing }
        naturalSpeech.endNaturally()
        precondition(natural.captions.count == 1)
        let naturalID = natural.captions[0].id
        natural.beginCaptionEditing(naturalID)
        try await waitUntil { natural.editingCaptionID == naturalID && !natural.isPreparingCaptionEdit }
        precondition(natural.editingCaptionID == naturalID && !natural.isPlaying)
        natural.cancelCaptionEditing()
        print("PASS merged live cards, empty recognition, naturally completed captions")

        let pausedSpeech = EditingSpeech()
        let paused = makeModel(clip: clip, speech: pausedSpeech)
        paused.currentTime = 2; paused.toggleRecording()
        try await waitUntil { pausedSpeech.isRecording && !paused.isTranscribing }
        paused.beginLiveCaptionEditing()
        try await waitUntil { paused.editingCaptionID != nil && !paused.isPreparingCaptionEdit }
        paused.saveCaptionEditing()
        precondition(!paused.isPlaying, "Finishing an edit must preserve the pre-recording paused state")
        paused.toggleRecording()
        try await waitUntil { pausedSpeech.isRecording && !paused.isTranscribing }
        paused.beginLiveCaptionEditing()
        try await waitUntil { paused.editingCaptionID != nil && !paused.isPreparingCaptionEdit }
        paused.cancelCaptionEditing()
        precondition(!paused.isPlaying, "Cancel must also preserve the pre-recording paused state")

        let startingSpeech = EditingSpeech(); startingSpeech.startDelay = 90_000_000
        let starting = makeModel(clip: clip, speech: startingSpeech)
        starting.captions = [previous]; starting.toggleRecording()
        precondition(starting.isTranscribing && !startingSpeech.isRecording)
        starting.beginCaptionEditing(previous.id); starting.beginLiveCaptionEditing()
        precondition(starting.editingCaptionID == nil && !starting.isPreparingCaptionEdit,
                     "A click while permission or microphone startup is pending must not open an old card")
        try await waitUntil { startingSpeech.isRecording && !starting.isTranscribing }
        await starting.finishRecording()

        let finishingSpeech = EditingSpeech()
        let finishing = makeModel(clip: clip, speech: finishingSpeech)
        finishing.captions = [previous]; finishing.play(); finishing.toggleRecording()
        try await waitUntil { finishingSpeech.isRecording && !finishing.isTranscribing }
        let pendingFinish = Task { await finishing.finishRecording() }
        try await waitUntil { finishing.isTranscribing && !finishingSpeech.isRecording }
        finishing.beginCaptionEditing(previous.id)
        try await waitUntil { finishing.editingCaptionID == previous.id && !finishing.isPreparingCaptionEdit }
        await pendingFinish.value
        precondition(finishingSpeech.stops == 1 && !finishing.isPlaying,
                     "Editing during finalization waits for the existing stop and keeps the picture paused")
        precondition(finishing.captionEditDraft.contains(previous.text) && finishing.captionEditDraft.contains(finishingSpeech.finalText),
                     "The card must be read after the speech tail has been committed")
        finishing.cancelCaptionEditing()
        print("PASS live paused-state policy, startup guard, editing during a single pending finalization")

        try checkRenderedIdentity(clipID: clip.id)
        for instance in [model, auto, live, merging, silent, natural, paused, starting, finishing] { await instance.prepareToTerminate() }
        print("PASS caption editing without microphone or speech-service access")
    }

    @MainActor private static func makeModel(clip: MediaClip, speech: EditingSpeech) -> AppModel {
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, speechInput: speech)
        model.automaticEditEnabled = false; model.orderMode = .manual; model.clips = [clip]
        return model
    }
    private static func unchangedPlacement(_ a: Caption, _ b: Caption) -> Bool {
        a.id == b.id && a.clipID == b.clipID && a.start == b.start && a.duration == b.duration && a.style == b.style
    }
    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Caption editing state did not settle")
    }
    @MainActor private static func checkRenderedIdentity(clipID: UUID) throws {
        let subtitle = Caption(clipID: clipID, start: 0, duration: 3, text: "相同内容", style: .subtitle)
        let sticker = Caption(clipID: clipID, start: 0, duration: 3, text: "相同内容", style: .sticker)
        let note = Caption(clipID: clipID, start: 2, duration: 3, text: "手记", style: .note)
        let blank = Caption(clipID: clipID, start: 0, duration: 3, text: " \n ", style: .note)
        let layers = MediaEngine.renderedCaptions([note, blank, sticker, subtitle], canvas: CGSize(width: 1920, height: 1080))
        precondition(layers.compactMap { $0.value(forKey: "captionID") as? String } == [subtitle.id, sticker.id, note.id].map(\.uuidString),
                     "Filtered and sorted rendered layers require explicit IDs instead of caller array indices")
        let duplicate = Caption(clipID: clipID, start: 1, duration: 3, text: subtitle.text, style: subtitle.style)
        let cached = MediaEngine.renderedCaptions([subtitle, duplicate], canvas: CGSize(width: 1920, height: 1080))
        precondition(Set(cached.compactMap { $0.value(forKey: "captionID") as? String }) == Set([subtitle.id.uuidString, duplicate.id.uuidString]),
                     "Shared raster cache must not share caption identity")
        let longCards = (0..<5).map { index in
            Caption(clipID: clipID, start: Double(index) * 0.01, duration: 4, text: String(repeating: "这是一句需要完整显示的中文感想。", count: 20), style: .note)
        }
        let compact = MediaEngine.renderedCaptions(longCards, canvas: CGSize(width: 1080, height: 1920))
        precondition(compact.contains { $0.name == "caption-compact" })
        precondition(Set(compact.compactMap { $0.value(forKey: "captionID") as? String }) == Set(longCards.map { $0.id.uuidString }),
                     "Compact layout names cannot erase hit-test identifiers")
        print("PASS rendered identity through whitespace filtering, sorting, raster caching, and compact layout")
    }
}
