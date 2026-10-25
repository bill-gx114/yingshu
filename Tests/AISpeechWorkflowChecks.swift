import AppKit
import Combine
import Foundation

@MainActor
private final class AISpeechFixture: SpeechInput {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var originalTranscript: String?
    var cleanupApplied = false
    var cleanupIssue: String?
    var status = "AI 测试状态"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = false
    var hasFinalResult = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    var delayStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var stopWaiter: (UUID, CheckedContinuation<String, Never>)?
    private var session: UUID?
    var configured: SpeechRecognitionOptions?
    var startCount = 0
    func configure(options: SpeechRecognitionOptions) { configured = options }
    func start() async throws {
        startCount += 1
        let id = UUID(); session = id
        transcript = ""; originalTranscript = nil; cleanupApplied = false; cleanupIssue = nil
        if delayStart { await withCheckedContinuation { startWaiter = $0 } }
        guard session == id else { throw CancellationError() }
        isRecording = true
    }
    func stop() async -> String {
        guard let id = session else { return transcript }
        isRecording = false
        return await withCheckedContinuation { stopWaiter = (id, $0) }
    }
    func complete(_ text: String, original: String, issue: String? = nil) {
        guard let (id, waiter) = stopWaiter else { preconditionFailure("No stop request") }
        stopWaiter = nil
        if session == id {
            transcript = text; originalTranscript = original
            cleanupApplied = text != original && issue == nil; cleanupIssue = issue; session = nil
        }
        waiter.resume(returning: text)
    }
    func releaseStart() { let waiter = startWaiter; startWaiter = nil; waiter?.resume() }
    func cancel() { isRecording = false; session = nil }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String { "" }
}

@main
struct AISpeechWorkflowChecks {
    @MainActor private static let defaultsSuite = "YingShu.AISpeechWorkflowChecks.\(UUID().uuidString)"
    @MainActor private static let isolatedDefaults = UserDefaults(suiteName: defaultsSuite)!
    @MainActor static func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Timed out")
    }
    @MainActor private static func make(_ speech: AISpeechFixture) -> AppModel {
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: speech, terminationSpeechGracePeriod: 0.15, profileDefaults: isolatedDefaults)
        let clip = MediaClip(url: URL(fileURLWithPath: "/tmp/yingshu-generated-ai-scene.png"), name: "合成测试场景", kind: .image, duration: 12, sourceDuration: 12)
        model.clips = [clip]; model.selectedClipID = clip.id; model.automaticEditEnabled = false
        model.updateSpeechMode(.localAI)
        return model
    }
    @MainActor static func main() async {
        defer { isolatedDefaults.removePersistentDomain(forName: defaultsSuite) }
        let speech = AISpeechFixture()
        // Use a separately injected instance so metadata comes from the actual stop callback.
        let active = make(speech)
        active.seek(to: 2); active.play()
        let before = active.undoCount
        active.toggleRecording()
        await wait { speech.isRecording && !active.isTranscribing }
        precondition(!active.isPlaying && active.currentTime >= 2 && active.currentTime < 2.2)
        let frozenTime = active.currentTime
        let stop = Task { await active.finishRecording() }
        await wait { active.isTranscribing && speech.stopWaiter != nil }
        precondition(active.captions.isEmpty && active.editingCaptionID == nil && active.canCancelRecordingPreparation)
        active.play(); active.seek(to: 8)
        precondition(!active.isPlaying && active.currentTime == frozenTime)
        let raw = "嗯，今天今天我们去了阿苏，风很舒服。"
        let generated = "今天我们去了阿苏，风很舒服。"
        let final = "今天我们去了阿苏，风很舒服"
        speech.complete(generated, original: raw)
        await stop.value
        precondition(active.captions.count == 1 && active.captions[0].text == final)
        precondition(active.captions[0].originalTranscript == raw && active.captions[0].clipID == active.clips[0].id)
        precondition(active.editingCaptionID == nil && active.isPlaying && !active.isTranscribing)
        precondition(active.undoCount == before + 1 && active.status.contains("已识别并整理"))
        active.pause()
        let stored = active.captions[0]
        active.restoreCaptionOriginal(stored.id)
        precondition(active.captions[0].text == raw && active.captions[0].start == stored.start && active.captions[0].duration == stored.duration)
        active.undoEdit(); precondition(active.captions == [stored])
        active.undoEdit(); precondition(active.captions.isEmpty, "One undo removes the complete AI take")
        active.redoEdit(); precondition(active.captions == [stored])

        // Failure to organize is visible; raw text is saved once with no invented success.
        let failureSpeech = AISpeechFixture()
        let fallback = make(failureSpeech)
        fallback.toggleRecording(); await wait { failureSpeech.isRecording && !fallback.isTranscribing }
        let fallbackStop = Task { await fallback.finishRecording() }
        await wait { failureSpeech.stopWaiter != nil }
        failureSpeech.complete(raw, original: raw, issue: "整理未通过，保留识别原文。")
        await fallbackStop.value
        precondition(fallback.captions[0].text == "嗯，今天今天我们去了阿苏，风很舒服" &&
            fallback.captions[0].originalTranscript == raw && fallback.status.contains("整理未通过") && !fallback.status.contains("已识别并整理"))
        fallback.pause()

        // Presentation drops only a final stop; the recognition record remains
        // exact, including emotional punctuation and sentence boundaries.
        let punctuationCases = [
            ("平静的一天。", "平静的一天"),
            ("平静的一天.", "平静的一天"),
            ("你听到了吗？", "你听到了吗？"),
            ("真的太美了！", "真的太美了！"),
            ("慢慢走……", "慢慢走……"),
            ("慢慢走...", "慢慢走..."),
            ("先看海。再去山里。", "先看海。再去山里")
        ]
        for (recognized, shown) in punctuationCases {
            let punctuationSpeech = AISpeechFixture(), punctuationModel = make(punctuationSpeech)
            punctuationModel.toggleRecording()
            await wait { punctuationSpeech.isRecording && !punctuationModel.isTranscribing }
            let punctuationStop = Task { await punctuationModel.finishRecording(autoResume: false) }
            await wait { punctuationSpeech.stopWaiter != nil }
            punctuationSpeech.complete(recognized, original: recognized)
            await punctuationStop.value
            precondition(punctuationModel.captions.count == 1 && punctuationModel.captions[0].text == shown,
                "Recognition caption changed meaningful punctuation: \(recognized)")
            let caption = punctuationModel.captions[0]
            precondition(caption.originalTranscript == recognized, "Display formatting changed the recognition record")
            punctuationModel.restoreCaptionOriginal(caption.id)
            precondition(punctuationModel.captions[0].text == recognized)
            if shown != recognized {
                punctuationModel.undoEdit()
                precondition(punctuationModel.captions[0] == caption, "Undo must restore the displayed form")
            }
            await punctuationModel.prepareToTerminate()
        }
        active.beginCaptionEditing(stored.id)
        active.captionEditDraft = "这句是我手写的。"
        active.saveCaptionEditing()
        precondition(active.captions[0].text == "这句是我手写的。", "Explicit manual punctuation must stay intact")
        active.undoEdit(); precondition(active.captions == [stored])
        let punctuationOnlySpeech = AISpeechFixture(), punctuationOnly = make(punctuationOnlySpeech)
        let punctuationOnlyUndoCount = punctuationOnly.undoCount
        punctuationOnly.toggleRecording()
        await wait { punctuationOnlySpeech.isRecording && !punctuationOnly.isTranscribing }
        let punctuationOnlyStop = Task { await punctuationOnly.finishRecording(autoResume: false) }
        await wait { punctuationOnlySpeech.stopWaiter != nil }
        punctuationOnlySpeech.complete("。", original: "。")
        await punctuationOnlyStop.value
        precondition(punctuationOnly.captions.isEmpty && punctuationOnly.undoCount == punctuationOnlyUndoCount,
            "A punctuation-only recognition result must not create an empty caption or undo entry")
        await punctuationOnly.prepareToTerminate()
        print("PASS recognition removes final periods while retaining questions, exclamations, ellipses, internal stops, raw provenance and explicit manual punctuation")

        // Cancel a cold model start. A non-cooperative late return cannot open the microphone state.
        let coldSpeech = AISpeechFixture()
        let preparing = make(coldSpeech); coldSpeech.delayStart = true
        preparing.toggleRecording(); await wait { coldSpeech.startWaiter != nil }
        preparing.cancelRecordingPreparation(); coldSpeech.releaseStart()
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(!preparing.isTranscribing && !coldSpeech.isRecording && preparing.captions.isEmpty && preparing.errorMessage == nil)

        // A canceled finalization cannot clear the anchor of the next take.
        let lateSpeech = AISpeechFixture(), late = make(lateSpeech)
        late.toggleRecording(); await wait { lateSpeech.isRecording && !late.isTranscribing }
        let lateStop = Task { await late.finishRecording() }
        await wait { lateSpeech.stopWaiter != nil }
        late.cancelRecordingPreparation()
        late.toggleRecording(); await wait { lateSpeech.isRecording && !late.isTranscribing }
        lateSpeech.complete("迟到结果", original: "迟到结果")
        await lateStop.value
        precondition(late.captions.isEmpty && lateSpeech.isRecording && !late.isTranscribing)
        let newStop = Task { await late.finishRecording(autoResume: false) }
        await wait { lateSpeech.stopWaiter != nil }
        lateSpeech.complete(generated, original: raw)
        await newStop.value
        precondition(late.captions.count == 1 && late.captions[0].text == final)
        // A canceled task that has not even been scheduled cannot steal the next anchor.
        let quickSpeech = AISpeechFixture(), quick = make(quickSpeech)
        quick.toggleRecording(); quick.cancelRecordingPreparation(); quick.toggleRecording()
        await wait { quickSpeech.isRecording && !quick.isTranscribing }
        precondition(quickSpeech.startCount == 1)
        let quickStop = Task { await quick.finishRecording(autoResume: false) }
        await wait { quickSpeech.stopWaiter != nil }
        quickSpeech.complete(generated, original: raw); await quickStop.value
        precondition(quick.captions.count == 1 && quick.captions[0].text == final)

        // Exit cannot await the backend's entire request timeout.
        let exitSpeech = AISpeechFixture(), exiting = make(exitSpeech)
        exiting.toggleRecording(); await wait { exitSpeech.isRecording && !exiting.isTranscribing }
        let began = ProcessInfo.processInfo.systemUptime
        await exiting.prepareToTerminate()
        precondition(ProcessInfo.processInfo.systemUptime - began < 0.8)
        precondition(!exiting.isTranscribing && !exitSpeech.isRecording && exiting.captions.isEmpty)
        exitSpeech.complete("退出后的迟到文字", original: "退出后的迟到文字")
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(exiting.captions.isEmpty)
        print("PASS AI final text/raw provenance commit directly without editor, paused processing/resume, single undo, restore, transparent cleanup failure, canceled startup and late finalization isolation; injected model data only")
    }
}
