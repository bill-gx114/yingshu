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
    var count: Int { inputs.count }
}

@main
struct CaptionCleanupStateChecks {
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
        let gate = CleanupGate()
        let speech = CleanupSpeech()
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
            speechInput: speech, captionCleaner: { try await gate.run($0, $1) },
            captionAIAvailability: { .init(isAvailable: true, message: "测试模型") })
        let clip = MediaClip(url: directory.appendingPathComponent("fixture.png"), name: "公开合成场景", kind: .image, duration: 8, sourceDuration: 8)
        let raw = Caption(clipID: clip.id, start: 1.5, duration: 4, text: "嗯，福冈今天的海风，海风很舒服。", style: .note, originalTranscript: "嗯，福冈今天的海风，海风很舒服。")
        model.clips = [clip]; model.selectedClipID = clip.id; model.captions = [raw]; model.automaticEditEnabled = false
        model.updateSpeechVocabulary("福冈，博多\n福冈")
        precondition(model.document.speechVocabulary == ["福冈", "博多"])
        model.beginCaptionCleanup(raw.id)
        await settle { model.isCleaningCaption }
        for _ in 0..<100 { if await gate.count > 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.captions == [raw], "AI request never changes the project")
        let suggested = "福冈今天的海风很舒服。"
        await gate.finish(suggested)
        await settle { model.captionCleanupSuggestion != nil }
        precondition(model.captionEditDraft == raw.text && model.captions == [raw])
        model.adoptCaptionCleanupSuggestion()
        precondition(model.captionEditDraft == suggested && model.captions == [raw])
        model.restoreCaptionCleanupOriginal()
        precondition(model.captionEditDraft == raw.text)
        model.requestCaptionCleanup()
        for _ in 0..<100 { if await gate.count > 1 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        await gate.finish(suggested)
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
        precondition(model.captionCleanupIssue == "测试模型暂不可用" && model.errorMessage == nil && model.captions == [corrected])
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
            speechInput: CleanupSpeech(), captionAIAvailability: { .init(isAvailable: false, message: "本地模型不可用") })
        unavailable.clips = [clip]; unavailable.selectedClipID = clip.id; unavailable.captions = [raw]
        unavailable.beginCaptionCleanup(raw.id)
        precondition(!unavailable.isCleaningCaption && unavailable.captionCleanupIssue == "本地模型不可用")
        unavailable.captionEditDraft = "  今天，， 风很舒服  "
        unavailable.basicCleanCaptionDraft()
        precondition(unavailable.captionEditDraft != "  今天，， 风很舒服  " && unavailable.captions == [raw])
        unavailable.cancelCaptionEditing()
        precondition(unavailable.captions == [raw])
        print("PASS: cleanup suggestions, original text, adoption/undo, stale tasks, failures, project replacement, vocabulary persistence and speech configuration")
    }
}
