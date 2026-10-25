import AppKit
import Combine
import Foundation

@MainActor
private final class CleanupSpeech: SpeechInput {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var isRecording = false
    var transcript = "福冈的海风很舒服。"
    var status = ""
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    var configured: SpeechRecognitionOptions?
    func configure(options: SpeechRecognitionOptions) { configured = options }
    func start() async throws { isRecording = true }
    func stop() async -> String { isRecording = false; return transcript }
    func cancel() { isRecording = false }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String { transcript }
}

private actor CleanupGate {
    var waiter: CheckedContinuation<String, Error>?
    var inputs: [(String, [String])] = []
    func run(_ text: String, _ terms: [String]) async throws -> String {
        inputs.append((text, terms))
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func finish(_ text: String) { let value = waiter; waiter = nil; value?.resume(returning: text) }
    func fail() { let value = waiter; waiter = nil; value?.resume(throwing: StudioError.message("测试模型暂不可用")) }
    func reject() { let value = waiter; waiter = nil; value?.resume(throwing: SpeechTextCleanupError.rejected("测试结果遗漏了原文")) }
    var count: Int { inputs.count }
}

@main
struct CaptionCleanupStateChecks {
    @MainActor private static func waitForCall(_ gate: CleanupGate, count: Int) async {
        for _ in 0..<100 {
            if await gate.count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await gate.count
        precondition(actual >= count, "Timed out waiting for cleaner input")
    }
    @MainActor static func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(predicate(), "Timed out waiting for state")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "YingShu.CaptionCleanupStateChecks.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let gate = CleanupGate()
        let speech = CleanupSpeech()
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: speech, captionCleaner: { try await gate.run($0, $1) },
            captionAIAvailability: { .init(isAvailable: true, message: "测试模型") }, profileDefaults: isolatedDefaults)
        let clip = MediaClip(url: directory.appendingPathComponent("fixture.png"), name: "公开合成场景", kind: .image, duration: 8, sourceDuration: 8)
        let raw = Caption(clipID: clip.id, start: 1.5, duration: 4, text: "嗯，福冈今天的海风，海风很舒服。", style: .note, originalTranscript: "嗯，福冈今天的海风，海风很舒服。")
        model.clips = [clip]; model.selectedClipID = clip.id; model.captions = [raw]; model.automaticEditEnabled = false
        model.updateSpeechVocabulary("福冈，博多\n福冈")
        precondition(model.document.speechVocabulary == ["福冈", "博多"])
        model.beginCaptionCleanup(raw.id)
        await settle { model.isCleaningCaption }
        for _ in 0..<100 { if await gate.count > 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.captions == [raw], "AI request never changes the project")
        let suggestedResult = "福冈今天的海风很舒服。"
        let suggested = "福冈今天的海风很舒服"
        await gate.finish(suggestedResult)
        await settle { model.captionCleanupSuggestion != nil }
        precondition(model.captionEditDraft == raw.text && model.captions == [raw])
        model.adoptCaptionCleanupSuggestion()
        precondition(model.captionEditDraft == suggested && model.captions == [raw])
        model.restoreCaptionCleanupOriginal()
        precondition(model.captionEditDraft == raw.text)
        model.requestCaptionCleanup()
        for _ in 0..<100 { if await gate.count > 1 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        await gate.finish(suggestedResult)
        await settle { model.captionCleanupSuggestion != nil }
        model.adoptCaptionCleanupSuggestion(); model.saveCaptionEditing()
        let corrected = model.captions[0]
        precondition(corrected.text == suggested && corrected.originalTranscript == raw.originalTranscript)
        precondition(corrected.id == raw.id && corrected.start == raw.start && corrected.duration == raw.duration && corrected.style == raw.style)
        model.undoEdit(); precondition(model.captions == [raw], "Adoption is one undoable edit")
        model.redoEdit(); precondition(model.captions == [corrected])

        // A non-cooperative late model must not overwrite manual corrections or a closed editor.
        model.beginCaptionCleanup(raw.id)
        for _ in 0..<100 { if await gate.count > 2 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        model.captionEditDraft = "这是我自己改的句子。"
        precondition(!model.isCleaningCaption && model.captionCleanupSuggestion == nil)
        await gate.finish("旧建议不能回来")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.captionEditDraft == "这是我自己改的句子。" && model.captions == [corrected])
        model.requestCaptionCleanup()
        for _ in 0..<100 { if await gate.count > 3 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        model.cancelCaptionEditing()
        await gate.finish("关闭后的迟到建议")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.editingCaptionID == nil && model.captions == [corrected])

        model.beginCaptionCleanup(raw.id)
        for _ in 0..<100 { if await gate.count > 4 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        await gate.fail()
        await settle { !model.isCleaningCaption }
        precondition(model.captionCleanupIssue == "测试模型暂不可用" && model.captionCleanupFeedbackKind == .failure && model.errorMessage == nil && model.captions == [corrected])
        model.cancelCaptionEditing()

        // Project replacement can reuse a caption ID; neither ID nor text alone is a safe token.
        let projectURL = directory.appendingPathComponent("same-id.json")
        try model.writeDocument(to: projectURL)
        model.beginCaptionCleanup(raw.id)
        for _ in 0..<100 { if await gate.count > 5 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        try model.applyDocument(from: projectURL)
        await gate.finish("另一个项目的迟到结果")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.editingCaptionID == nil && model.captionCleanupSuggestion == nil && model.captions == [corrected])
        precondition(model.document.speechVocabulary == ["福冈", "博多"])
        model.isShowingSpeechSettings = true
        precondition(!model.canEditStructure && !model.canOpenCaptionEditor)
        model.play(); precondition(!model.isPlaying, "Settings prevent background playback")
        model.updateSpeechMode(.systemService)
        precondition(model.speechMode == .systemService, "Explicit mode changes work inside settings")
        model.isShowingSpeechSettings = false
        try model.writeDocument(to: projectURL)
        try model.applyDocument(from: projectURL)
        precondition(model.speechMode == .systemService)
        model.updateSpeechMode(.localFirst)
        model.seek(to: 0); model.toggleRecording()
        await settle { speech.isRecording && !model.isTranscribing }
        precondition(speech.configured?.mode == .localFirst && speech.configured?.contextualStrings.contains("福冈") == true)
        await model.finishRecording(autoResume: false)
        precondition(model.captions.contains { $0.originalTranscript?.contains(speech.transcript) == true })

        let unavailable = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: CleanupSpeech(), captionAIAvailability: { .init(isAvailable: false, message: "本地模型不可用") },
            profileDefaults: isolatedDefaults)
        unavailable.clips = [clip]; unavailable.selectedClipID = clip.id; unavailable.captions = [raw]
        unavailable.beginCaptionCleanup(raw.id)
        precondition(!unavailable.isCleaningCaption && unavailable.captionCleanupIssue == "本地模型不可用" && unavailable.captionCleanupFeedbackKind == .failure)
        unavailable.captionEditDraft = "  今天，， 风很舒服  "
        precondition(unavailable.captionCleanupIssue == nil, "Editing clears unavailable feedback even when no AI input snapshot exists")
        unavailable.basicCleanCaptionDraft()
        precondition(unavailable.captionEditDraft != "  今天，， 风很舒服  " && unavailable.captions == [raw] && unavailable.captionCleanupFeedbackKind == .information)
        unavailable.cancelCaptionEditing()
        precondition(unavailable.captions == [raw])

        // AI result formatting is presentation-only: keep meaningful endings,
        // and retain the exact input until a formatted suggestion is adopted.
        let punctuationGate = CleanupGate()
        let punctuationModel = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: CleanupSpeech(), captionCleaner: { try await punctuationGate.run($0, $1) },
            captionAIAvailability: { .init(isAvailable: true, message: "标点隔离测试") }, profileDefaults: isolatedDefaults)
        punctuationModel.clips = [clip]; punctuationModel.selectedClipID = clip.id
        punctuationModel.captions = [raw]; punctuationModel.automaticEditEnabled = false
        let punctuationCases = [
            ("平静的一天。", "平静的一天"),
            ("平静的一天.", "平静的一天"),
            ("你听到了吗？", "你听到了吗？"),
            ("真的太美了！", "真的太美了！"),
            ("慢慢走……", "慢慢走……"),
            ("慢慢走...", "慢慢走..."),
            ("先看海。再去山里。", "先看海。再去山里")
        ]
        for (index, item) in punctuationCases.enumerated() {
            let (result, shown) = item
            punctuationModel.beginCaptionEditing(raw.id)
            punctuationModel.captionEditDraft = result
            punctuationModel.requestCaptionCleanup()
            await waitForCall(punctuationGate, count: index + 1)
            await punctuationGate.finish(result)
            await settle { !punctuationModel.isCleaningCaption }
            precondition((punctuationModel.captionCleanupSuggestion ?? punctuationModel.captionEditDraft) == shown,
                "AI suggestion changed meaningful punctuation: \(result)")
            precondition(punctuationModel.captionEditDraft == result && punctuationModel.captions == [raw],
                "Formatting must not silently change the draft or saved project")
            precondition(punctuationModel.captionCleanupOriginalText == result, "AI input punctuation must remain restorable")
            if punctuationModel.captionCleanupSuggestion != nil {
                punctuationModel.adoptCaptionCleanupSuggestion()
                precondition(punctuationModel.captionEditDraft == shown)
                punctuationModel.restoreCaptionCleanupOriginal()
                precondition(punctuationModel.captionEditDraft == result)
            }
            punctuationModel.cancelCaptionEditing()
        }
        punctuationModel.beginCaptionEditing(raw.id)
        punctuationModel.captionEditDraft = "原本有正文"
        punctuationModel.requestCaptionCleanup()
        await waitForCall(punctuationGate, count: punctuationCases.count + 1)
        await punctuationGate.finish("。")
        await settle { !punctuationModel.isCleaningCaption }
        precondition(punctuationModel.captionCleanupSuggestion == nil && punctuationModel.captionEditDraft == "原本有正文" &&
            punctuationModel.captionCleanupFeedbackKind == .retainedOriginal && punctuationModel.captions == [raw],
            "A punctuation-only model result must preserve the draft rather than offer an empty replacement")
        punctuationModel.cancelCaptionEditing()
        punctuationModel.beginCaptionEditing(raw.id)
        punctuationModel.captionEditDraft = "已有的一句。"
        punctuationModel.basicCleanCaptionDraft()
        precondition(punctuationModel.captionEditDraft == "已有的一句" && punctuationModel.captionCleanupOriginalText == "已有的一句。" &&
            punctuationModel.captions == [raw], "Explicit basic cleanup applies the display preference without changing the saved project")
        punctuationModel.restoreCaptionCleanupOriginal()
        precondition(punctuationModel.captionEditDraft == "已有的一句。", "Basic cleanup must keep the exact input restorable")
        punctuationModel.captionEditDraft = "。"
        punctuationModel.basicCleanCaptionDraft()
        precondition(punctuationModel.captionEditDraft == "。" && punctuationModel.captions == [raw],
            "Basic cleanup must not replace a punctuation-only draft with empty text")
        punctuationModel.cancelCaptionEditing()
        punctuationModel.beginCaptionEditing(raw.id)
        punctuationModel.captionEditDraft = "这是手写的句子。"
        punctuationModel.saveCaptionEditing()
        precondition(punctuationModel.captions[0].text == "这是手写的句子。", "Saving manual text must not remove an explicitly typed period")
        punctuationModel.undoEdit(); precondition(punctuationModel.captions == [raw])
        print("PASS AI suggestions remove final stops only, preserve emotional/internal punctuation, retain raw input and leave manual text untouched")

        // Normal feedback, content-protection refusal and execution failures are
        // distinct states; none is allowed to change the saved caption by itself.
        let feedbackGate = CleanupGate()
        let feedback = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: CleanupSpeech(), captionCleaner: { try await feedbackGate.run($0, $1) },
            captionAIAvailability: { .init(isAvailable: true, message: "隔离测试模型") },
            profileDefaults: isolatedDefaults, captionCleanupTimeout: 0.2)
        feedback.clips = [clip]; feedback.selectedClipID = clip.id; feedback.captions = [raw]; feedback.automaticEditEnabled = false
        feedback.beginCaptionEditing(raw.id)
        let unchangedInput = "这句话无需修改"
        feedback.captionEditDraft = unchangedInput
        feedback.requestCaptionCleanup()
        await waitForCall(feedbackGate, count: 1)
        await feedbackGate.finish(unchangedInput)
        await settle { !feedback.isCleaningCaption }
        precondition(feedback.captionCleanupFeedbackKind == .information && feedback.captionCleanupIssue == "AI 已检查，这句话无需修改，可以直接完成。")
        precondition(feedback.captionCleanupSuggestion == nil && feedback.captionEditDraft == unchangedInput && feedback.captions == [raw])
        feedback.captionEditDraft = "我正在手动改字。"
        precondition(feedback.captionCleanupIssue == nil, "Editing clears the previous no-change result")

        feedback.captionEditDraft = "  画面，，  很美  "
        feedback.basicCleanCaptionDraft()
        precondition(feedback.captionCleanupFeedbackKind == .information && feedback.captionCleanupIssue != nil)
        feedback.captionEditDraft = "画面很美，我还想再改一句"
        precondition(feedback.captionCleanupIssue == nil, "Editing clears basic-clean feedback without an AI input snapshot")
        feedback.basicCleanCaptionDraft()
        precondition(feedback.captionCleanupFeedbackKind == .information && feedback.captionCleanupIssue == "空白与标点已经整齐，基础整理不会猜改错字。")
        feedback.captionEditDraft = "我把今天的感受写在记里"
        precondition(feedback.captionCleanupIssue == nil)
        feedback.requestCaptionCleanup()
        await waitForCall(feedbackGate, count: 2)
        await feedbackGate.reject()
        await settle { !feedback.isCleaningCaption }
        precondition(feedback.captionCleanupFeedbackKind == .retainedOriginal && feedback.captionCleanupIssue?.contains("AI 已处理") == true)
        precondition(feedback.captionEditDraft == "我把今天的感受写在记里" && feedback.captions == [raw] && feedback.captionCleanupSuggestion == nil)
        feedback.captionEditDraft = "我把今天的感受写在日记里"
        precondition(feedback.captionCleanupIssue == nil, "A manual correction clears the previous rejection")

        feedback.requestCaptionCleanup()
        await waitForCall(feedbackGate, count: 3)
        await feedbackGate.fail()
        await settle { !feedback.isCleaningCaption }
        precondition(feedback.captionCleanupFeedbackKind == .failure && feedback.captionCleanupIssue == "测试模型暂不可用")
        feedback.captionEditDraft = "我手动保留这句话。"
        precondition(feedback.captionCleanupIssue == nil)

        feedback.requestCaptionCleanup()
        await waitForCall(feedbackGate, count: 4)
        await settle { !feedback.isCleaningCaption }
        precondition(feedback.captionCleanupFeedbackKind == .failure && feedback.captionCleanupIssue?.contains("用时较长") == true)
        precondition(feedback.captionCleanupSuggestion == nil && feedback.captions == [raw])
        feedback.captionEditDraft = "超时后继续手动修改。"
        precondition(feedback.captionCleanupIssue == nil, "Editing clears timed-out feedback after its input snapshot has been discarded")
        await feedbackGate.finish("超时后的迟到建议不能采用")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(feedback.captionEditDraft == "超时后继续手动修改。" && feedback.captionCleanupIssue == nil && feedback.captionCleanupSuggestion == nil && feedback.captions == [raw])
        feedback.cancelCaptionEditing()
        print("PASS: typed no-change/basic/rejected/failure feedback, stale-message clearing and actual deadline prevent late edits")
        print("PASS: cleanup suggestions, original text, adoption/undo, stale tasks, failures, project replacement, vocabulary persistence and speech configuration")
    }
}
