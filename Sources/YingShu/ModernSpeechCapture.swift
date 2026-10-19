import AVFoundation
import Combine
import CoreMedia
import Foundation
import Speech

@MainActor
enum SpeechInputFactory {
    static func make() -> any SpeechInput { HybridSpeechCapture() }
}

/// Chooses a model only at the start of a session. Checking never installs assets.
@MainActor
final class HybridSpeechCapture: SpeechInput {
    private let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    private let legacy = SpeechCapture()
    private var current: any SpeechInput
    private var observation: AnyCancellable?
    private var options = SpeechRecognitionOptions()
    private var activeSessionID: UUID?
    private var hasActiveSession: Bool { activeSessionID != nil }
    private var selectionID: UUID?
    private var availabilityCheckID: UUID?
    private var availabilityQuery: Task<EnhancedSpeechModelAvailability, Never>?
    private var preparationID: UUID?
    private var installationTask: Task<Void, Error>?
    private var installationProgress: Progress?
    private var progressObservation: NSKeyValueObservation?
    private(set) var enhancedModelAvailability: EnhancedSpeechModelAvailability = .checking
    private(set) var enhancedModelDownloadProgress: Double?
    private var fallbackMessage: String?
    var onUnexpectedStop: ((String) -> Void)?

    init() {
        current = legacy
        observeCurrent()
        Task { [weak self] in await self?.refreshEnhancedModelAvailability() }
    }
    var isRecording: Bool { current.isRecording }
    var transcript: String { current.transcript }
    var originalTranscript: String? { current.originalTranscript }
    var cleanupApplied: Bool { current.cleanupApplied }
    var cleanupIssue: String? { current.cleanupIssue }
    var status: String {
        if let fallbackMessage, current.isRecording { return current.status + " " + fallbackMessage }
        return current.status
    }
    var audioLevel: Float { current.audioLevel }
    var authorizationGranted: Bool { current.authorizationGranted }
    var segments: [SpeechSegment] { current.segments }
    var wordSegments: [SpeechSegment] { current.wordSegments }
    var hasFinalTiming: Bool { current.hasFinalTiming }
    var hasFinalResult: Bool { current.hasFinalResult }
    var lastIssue: String? { current.lastIssue }
    var isRecognizingFile: Bool { current.isRecognizingFile }

    func configure(options: SpeechRecognitionOptions) { self.options = options }

    func refreshEnhancedModelAvailability() async {
        guard preparationID == nil else { return }
        let checkID: UUID
        let query: Task<EnhancedSpeechModelAvailability, Never>
        if let existing = availabilityQuery, let existingID = availabilityCheckID {
            checkID = existingID; query = existing
        } else {
            checkID = UUID(); query = Task { await Self.queryAvailability() }
            availabilityCheckID = checkID; availabilityQuery = query
        }
        let state = await query.value
        guard preparationID == nil, availabilityCheckID == checkID else { return }
        availabilityQuery = nil; availabilityCheckID = nil
        enhancedModelAvailability = state; updates.send()
    }

    private static func queryAvailability() async -> EnhancedSpeechModelAvailability {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
                return .unavailable("此 Mac 暂不支持增强中文模型；使用兼容语音识别。")
            }
            // AssetInventory.status also reflects this app's reservations. A locale can
            // already be installed globally while an unreserved module reports supported.
            // This check is read-only; reservation happens only when recognition starts.
            let installed = await SpeechTranscriber.installedLocales
            if installed.contains(where: { $0.identifier == locale.identifier }) { return .installed }
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            let state = await AssetInventory.status(forModules: [transcriber])
            switch state {
            case .installed: return .installed
            case .downloading: return .downloading
            case .supported: return .notInstalled
            case .unsupported: return .unavailable("此 Mac 暂不支持增强中文模型；使用兼容语音识别。")
            @unknown default: return .unavailable("系统暂时无法确认增强中文模型。")
            }
        }
        #endif
        return .unavailable("增强中文识别需要 macOS 26 或更新版本；当前使用兼容识别。")
    }

    /// Explicit user action only. Task cancellation cancels both installation and its Progress.
    func prepareEnhancedModel() async throws {
        guard selectionID == nil, !hasActiveSession, !isRecording, !isRecognizingFile, preparationID == nil else {
            throw SpeechRecognitionFailure.message("请先结束口述或当前模型下载。")
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let id = UUID(); preparationID = id
            availabilityCheckID = nil; availabilityQuery?.cancel(); availabilityQuery = nil
            enhancedModelAvailability = .downloading; enhancedModelDownloadProgress = nil; updates.send()
            do {
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
                    throw SpeechRecognitionFailure.message("此 Mac 暂不支持增强中文模型。")
                }
                try Task.checkCancellation()
                guard preparationID == id else { throw CancellationError() }
                let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
                let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                try Task.checkCancellation()
                guard preparationID == id else { throw CancellationError() }
                if let request {
                    enhancedModelDownloadProgress = request.progress.totalUnitCount > 0 ? request.progress.fractionCompleted : nil
                    installationProgress = request.progress
                    progressObservation = request.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                        let fraction = progress.totalUnitCount > 0 ? max(0, min(1, progress.fractionCompleted)) : nil
                        Task { @MainActor [weak self] in
                            guard let self, self.preparationID == id else { return }
                            self.enhancedModelDownloadProgress = fraction; self.updates.send()
                        }
                    }
                    let task = Task { try await request.downloadAndInstall() }
                    installationTask = task; updates.send()
                    try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                        request.progress.cancel(); task.cancel()
                    })
                }
                try Task.checkCancellation()
                guard preparationID == id else { throw CancellationError() }
                clearPreparation()
                await refreshEnhancedModelAvailability()
                guard enhancedModelAvailability == .installed else {
                    throw SpeechRecognitionFailure.message("增强中文模型尚未就绪，请稍后重试。")
                }
            } catch {
                if preparationID == id { clearPreparation(); await refreshEnhancedModelAvailability() }
                throw error
            }
            return
        }
        #endif
        throw SpeechRecognitionFailure.message("增强中文识别需要 macOS 26 或更新版本。")
    }
    private func clearPreparation() {
        preparationID = nil; progressObservation = nil; installationTask = nil
        installationProgress = nil; enhancedModelDownloadProgress = nil; updates.send()
    }
    func cancelEnhancedModelPreparation() {
        guard preparationID != nil else { return }
        installationProgress?.cancel(); installationTask?.cancel()
        clearPreparation()
        Task { [weak self] in await self?.refreshEnhancedModelAvailability() }
    }

    func start() async throws {
        guard selectionID == nil, !hasActiveSession, !isRecording, !isRecognizingFile, preparationID == nil else {
            throw SpeechRecognitionFailure.message("上一项语音任务尚未结束。")
        }
        let id = UUID(); selectionID = id
        defer { if selectionID == id { selectionID = nil } }
        try await chooseBackend(forceSystemService: false, id: id, options: options)
        let backend = current
        activeSessionID = id
        do { try await backend.start() } catch { if activeSessionID == id { activeSessionID = nil }; throw error }
        guard selectionID == id else { backend.cancel(); throw CancellationError() }
    }
    func transcribeFile(url: URL, requireOnDevice: Bool? = nil) async throws -> String {
        guard selectionID == nil, !hasActiveSession, !isRecording, !isRecognizingFile, preparationID == nil else {
            throw SpeechRecognitionFailure.message("请先结束当前语音任务。")
        }
        let id = UUID(); selectionID = id
        defer { if selectionID == id { selectionID = nil } }
        try await chooseBackend(forceSystemService: requireOnDevice == false, id: id, options: options)
        let backend = current
        activeSessionID = id
        defer { if activeSessionID == id { activeSessionID = nil } }
        return try await backend.transcribeFile(url: url, requireOnDevice: requireOnDevice)
    }
    private func chooseBackend(forceSystemService: Bool, id: UUID, options: SpeechRecognitionOptions) async throws {
        let system = forceSystemService || options.mode == .systemService
        if !system && options.mode != .localAI { await refreshEnhancedModelAvailability() }
        try Task.checkCancellation()
        guard selectionID == id else { throw CancellationError() }
        current.onUnexpectedStop = nil
        fallbackMessage = nil
        if !system && options.mode == .localAI {
            current = LocalAISpeechCapture()
            current.configure(options: options)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), !system, enhancedModelAvailability == .installed {
                current = ModernSpeechCapture()
            } else {
                current = legacy
                if !system { fallbackMessage = enhancedModelAvailability.message }
            }
            #else
            current = legacy
            if !system { fallbackMessage = enhancedModelAvailability.message }
            #endif
            current.configure(options: SpeechRecognitionOptions(mode: system ? .systemService : .localFirst,
                                                               contextualStrings: options.contextualStrings))
        }
        observeCurrent(); updates.send()
    }
    private func observeCurrent() {
        observation = current.changes.sink { [weak self] in self?.updates.send() }
        current.onUnexpectedStop = { [weak self] text in self?.activeSessionID = nil; self?.onUnexpectedStop?(text) }
    }
    func stop() async -> String {
        if selectionID != nil, !current.isRecording, !current.isRecognizingFile { cancel(); return "" }
        let id = activeSessionID, backend = current
        let text = await backend.stop()
        if activeSessionID == id { activeSessionID = nil }
        return text
    }
    func cancel() { activeSessionID = nil; selectionID = nil; current.cancel(); updates.send() }
}

/// Independent of the system recognizer so revision and punctuation behavior is testable.
struct SpeechPassage: Equatable, Sendable {
    var start: Double
    var end: Double
    var words: [SpeechSegment]
    var isFinal: Bool
    var hasTiming: Bool
}

struct SpeechTranscriptAccumulator {
    private struct Entry { var word: SpeechSegment; var isFinal: Bool; var hasTiming: Bool; var order: Int }
    private var entries: [Entry] = []
    private var nextOrder = 0
    mutating func apply(_ passage: SpeechPassage) {
        guard passage.start.isFinite, passage.end.isFinite, passage.end >= passage.start,
              !passage.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        func overlaps(_ start: Double, _ end: Double, _ lower: Double, _ upper: Double) -> Bool {
            max(start, lower) < min(max(start + 0.000_001, end), max(lower + 0.000_001, upper))
        }
        // A volatile revision must never undo finalized text. With word timings only the
        // revised range is replaced, rather than an entire earlier passage's prefix.
        let protected = entries.filter { $0.isFinal && !passage.isFinal }
        entries.removeAll { entry in
            (!entry.isFinal || passage.isFinal) && overlaps(entry.word.timestamp, entry.word.end, passage.start, passage.end)
        }
        for word in passage.words where !word.text.isEmpty {
            guard !protected.contains(where: { overlaps($0.word.timestamp, $0.word.end, word.timestamp, word.end) }) else { continue }
            entries.append(Entry(word: word, isFinal: passage.isFinal, hasTiming: passage.hasTiming, order: nextOrder))
            nextOrder += 1
        }
        entries.sort { $0.word.timestamp == $1.word.timestamp ? $0.order < $1.order : $0.word.timestamp < $1.word.timestamp }
    }
    var hasFinalResult: Bool { !entries.isEmpty && entries.allSatisfy(\.isFinal) }
    var hasFinalTiming: Bool { hasFinalResult && entries.allSatisfy { $0.hasTiming && $0.word.duration > 0 } }
    var snapshot: (text: String, words: [SpeechSegment]) {
        let raw = entries.map { $0.word.text }.joined()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", []) }
        let rawNS = raw as NSString, textNS = text as NSString
        let offset = rawNS.range(of: text).location
        var cursor = 0
        let words: [SpeechSegment] = entries.compactMap { entry in
            let length = (entry.word.text as NSString).length
            defer { cursor += length }
            let lower = max(0, cursor - offset), upper = min(textNS.length, cursor + length - offset)
            guard upper > lower else { return nil }
            var word = entry.word
            word.utf16Range = NSRange(location: lower, length: upper - lower)
            word.text = textNS.substring(with: word.utf16Range)
            return word
        }
        return (text, words)
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
@MainActor
final class ModernSpeechCapture: ObservableObject, SpeechInput {
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = "按 R，说出这一刻的感想。"
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var authorizationGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var wordSegments: [SpeechSegment] = []
    @Published private(set) var hasFinalTiming = false
    @Published private(set) var hasFinalResult = false
    @Published private(set) var lastIssue: String?
    @Published private(set) var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    private var options = SpeechRecognitionOptions()
    private var sessionID: UUID?
    private var finishing = false
    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var bridge: ModernSpeechAudioInput?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var finishDeadline: Task<Void, Never>?
    private var fileDeadline: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var stopWaiters: [CheckedContinuation<String, Never>] = []
    private var fileWaiter: CheckedContinuation<String, Error>?
    private var accumulator = SpeechTranscriptAccumulator()

    func configure(options: SpeechRecognitionOptions) { self.options = options }

    private func begin() throws -> UUID {
        guard sessionID == nil else { throw SpeechRecognitionFailure.message("上一句口述尚未结束。") }
        let id = UUID(); sessionID = id; finishing = false
        transcript = ""; segments = []; wordSegments = []; hasFinalResult = false; hasFinalTiming = false
        audioLevel = 0; lastIssue = nil; accumulator = SpeechTranscriptAccumulator()
        return id
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation(); guard sessionID == id else { throw CancellationError() }
    }
    private func makeAnalyzer(id: UUID, options: SpeechRecognitionOptions) async throws -> (SpeechAnalyzer, SpeechTranscriber) {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw SpeechRecognitionFailure.message("此 Mac 当前无法使用增强中文识别。")
        }
        try check(id)
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == locale.identifier }) else {
            throw SpeechRecognitionFailure.message("增强中文模型尚未安装。请主动下载，或使用兼容识别。")
        }
        // Reserve already-installed assets for this app. reserve does not download;
        // retaining this one locale lets subsequent sessions reuse the system model.
        try await AssetInventory.reserve(locale: locale)
        try check(id)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechRecognitionFailure.message("增强中文模型尚未安装。请主动下载，或使用兼容识别。")
        }
        try check(id)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext(); context.contextualStrings[.general] = options.contextualStrings
        try await analyzer.setContext(context)
        try check(id)
        self.analyzer = analyzer
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.sessionID == id else { return }
                    self.receive(result, id: id)
                }
                guard let self, self.sessionID == id else { return }
                self.complete(id: id)
            } catch {
                guard let self, self.sessionID == id else { return }
                self.fail(error, id: id)
            }
        }
        return (analyzer, transcriber)
    }

    func start() async throws {
        let sessionOptions = options
        let id = try begin(); status = "正在准备增强本机中文识别…"
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
                throw SpeechRecognitionFailure.message("请从“映述.app”启动，以启用麦克风权限。")
            }
            let existing = AVCaptureDevice.authorizationStatus(for: .audio)
            var granted = existing == .authorized
            if existing == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            try check(id); authorizationGranted = granted
            guard granted else { throw SpeechRecognitionFailure.message("请在“系统设置 → 隐私与安全性 → 麦克风”中允许映述。") }
            let (analyzer, transcriber) = try await makeAnalyzer(id: id, options: sessionOptions)
            let engine = AVAudioEngine(), input = engine.inputNode
            let naturalFormat = input.outputFormat(forBus: 0)
            guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else {
                throw SpeechRecognitionFailure.message("没有可用的中文识别音频格式或麦克风。")
            }
            try check(id)
            try await analyzer.prepareToAnalyze(in: format)
            try check(id)
            let stream = AsyncStream<AnalyzerInput>.makeStream()
            let bridge = try ModernSpeechAudioInput(inputFormat: naturalFormat, analyzerFormat: format, continuation: stream.continuation, meter: { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id, self.isRecording else { return }; self.audioLevel = level
                }
            }, failure: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }; self.fail(error, id: id)
                }
            })
            self.bridge = bridge; self.engine = engine
            try await analyzer.start(inputSequence: stream.stream)
            try check(id)
            input.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { buffer, _ in bridge.append(buffer) }
            bridge.tapInstalled = true
            engine.prepare(); try engine.start()
            isRecording = true; status = "正在听 · 增强本机中文识别，不保存录音。"
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id, self.isRecording else { return }
                    self.fail(SpeechRecognitionFailure.message("麦克风设置发生变化，已停止口述。"), id: id)
                }
            }
        } catch { if sessionID == id { fail(error, id: id, unexpected: false) }; throw error }
    }

    func transcribeFile(url: URL, requireOnDevice: Bool? = nil) async throws -> String {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw SpeechRecognitionFailure.message("测试音频不存在或无法读取。")
        }
        let sessionOptions = options
        let id = try begin(); status = "正在检查增强中文识别，不使用麦克风…"; isRecognizingFile = true
        return try await withTaskCancellationHandler(operation: {
            do {
                let (analyzer, _) = try await makeAnalyzer(id: id, options: sessionOptions)
                try check(id)
                let file = try AVAudioFile(forReading: url)
                return try await withCheckedThrowingContinuation { continuation in
                    fileWaiter = continuation
                    analysisTask = Task { [weak self] in
                        do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
                        catch { guard let self, self.sessionID == id else { return }; self.fail(error, id: id) }
                    }
                    fileDeadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                        guard let self, self.sessionID == id else { return }
                        self.fail(SpeechRecognitionFailure.message("增强中文识别自检超时。"), id: id)
                    }
                }
            } catch { if sessionID == id { fail(error, id: id) }; throw error }
        }, onCancel: { [weak self] in Task { @MainActor [weak self] in if self?.sessionID == id { self?.cancel() } } })
    }

    func stop() async -> String {
        guard let id = sessionID else { return transcript }
        guard !isRecognizingFile else { return transcript }
        if !isRecording && !finishing { cancel(); return "" }
        if !finishing {
            finishing = true; isRecording = false; status = "正在确认最后几个字…"; audioLevel = 0
            stopAudio()
            if let analyzer {
                // Do not cancel the results reader: it must consume the finalized tail.
                analysisTask = Task { [weak self] in
                    do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                    catch { guard let self, self.sessionID == id else { return }; self.fail(error, id: id) }
                }
            }
            finishDeadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard let self, self.sessionID == id else { return }
                self.lastIssue = "已保留临时识别文字；系统未及时确认，末尾和时间位置可能不完整，请检查。"
                self.end(status: self.lastIssue!, error: nil, unexpected: false)
            }
        }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }

    func cancel() {
        transcript = ""; segments = []; wordSegments = []; hasFinalResult = false; hasFinalTiming = false
        end(status: "口述已取消。", error: CancellationError(), unexpected: false)
    }
    private func receive(_ result: SpeechTranscriber.Result, id: UUID) {
        guard sessionID == id, isRecognizingFile || bridge?.hasAudibleInput == true else { return }
        let attributed = result.text
        var words: [SpeechSegment] = []
        var pendingPrefix = ""
        var hasTiming = true
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.duration.seconds.isFinite, range.duration.seconds > 0 {
                if let previous = words.last, abs(previous.timestamp - range.start.seconds) < 0.0001,
                   abs(previous.duration - range.duration.seconds) < 0.0001 {
                    words[words.count - 1].text += text
                } else {
                    words.append(SpeechSegment(text: pendingPrefix + text, timestamp: range.start.seconds, duration: range.duration.seconds))
                    pendingPrefix = ""
                }
            } else if !words.isEmpty { words[words.count - 1].text += text }
            else { pendingPrefix += text }
        }
        if words.isEmpty {
            hasTiming = false
            words = [SpeechSegment(text: String(attributed.characters), timestamp: result.range.start.seconds,
                                   duration: max(0, result.range.duration.seconds))]
        }
        accumulator.apply(SpeechPassage(start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                                        words: words, isFinal: result.isFinal, hasTiming: hasTiming))
        let snapshot = accumulator.snapshot
        transcript = snapshot.text; wordSegments = snapshot.words
        segments = SpeechCapture.shortPhrases(from: wordSegments, transcript: transcript)
        hasFinalResult = accumulator.hasFinalResult; hasFinalTiming = accumulator.hasFinalTiming
    }
    private func complete(id: UUID) {
        guard sessionID == id else { return }
        if transcript.isEmpty && isRecognizingFile {
            fail(SpeechRecognitionFailure.message("识别完成，但这段测试音频没有返回文字。"), id: id)
        } else {
            end(status: transcript.isEmpty ? "没有听到清晰语音，请重试或使用“写一句”。" : "文字已就绪，可继续说下一句。",
                error: nil, unexpected: isRecording)
        }
    }
    private func fail(_ error: Error, id: UUID, unexpected: Bool? = nil) {
        guard sessionID == id else { return }
        let message = error is CancellationError ? "口述已取消。" : "增强中文识别未完成：\(error.localizedDescription)" + (transcript.isEmpty ? "" : " 已保留识别文字，末尾可能不完整。")
        if !(error is CancellationError) { lastIssue = message }
        end(status: message, error: error, unexpected: unexpected ?? isRecording)
    }
    private func stopAudio() {
        engine?.stop()
        if bridge?.tapInstalled == true { engine?.inputNode.removeTap(onBus: 0); bridge?.tapInstalled = false }
        bridge?.finish()
    }
    private func end(status: String, error: Error?, unexpected: Bool) {
        sessionID = nil; finishing = false; isRecording = false; isRecognizingFile = false; audioLevel = 0
        finishDeadline?.cancel(); finishDeadline = nil; fileDeadline?.cancel(); fileDeadline = nil
        stopAudio(); engine = nil; bridge = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; configurationObserver = nil
        let previousAnalyzer = analyzer; analyzer = nil
        analysisTask?.cancel(); analysisTask = nil; resultTask?.cancel(); resultTask = nil
        if let previousAnalyzer { Task { await previousAnalyzer.cancelAndFinishNow() } }
        self.status = status
        let text = transcript, waiters = stopWaiters; stopWaiters = []; waiters.forEach { $0.resume(returning: text) }
        let waiter = fileWaiter; fileWaiter = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: text) }
        if unexpected { onUnexpectedStop?(text) }
    }
}

/// Copies tap buffers and converts serially away from the realtime audio thread. No files.
@available(macOS 26.0, *)
final class ModernSpeechAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "YingShu.speech-audio-conversion", qos: .userInitiated)
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let meter: @Sendable (Float) -> Void
    private let failure: @Sendable (Error) -> Void
    private var accepting = true
    private var audibleSeconds: Double = 0
    private var lastMeter = 0.0
    private var convertedFrames: Int64 = 0
    var tapInstalled = false // Main actor owns tap installation/removal.
    init(inputFormat: AVAudioFormat, analyzerFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         meter: @escaping @Sendable (Float) -> Void, failure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        target = analyzerFormat; self.continuation = continuation; self.meter = meter; self.failure = failure
        if inputFormat == analyzerFormat { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                throw SpeechRecognitionFailure.message("无法转换麦克风音频格式。")
            }
            self.converter = converter
        }
    }
    var hasAudibleInput: Bool { lock.lock(); defer { lock.unlock() }; return audibleSeconds >= SpeechAudioMeasurement.minimumAudibleSeconds }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, input.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            if let fromData = from.mData, let toData = to.mData { memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize))) }
        }
        let rms = SpeechAudioMeasurement.rms(input)
        if rms > SpeechAudioMeasurement.minimumAudibleRMS, input.format.sampleRate > 0 {
            audibleSeconds += Double(input.frameLength) / input.format.sampleRate
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeter >= 0.075 {
            lastMeter = now; meter(max(0, min(1, (20 * log10(max(rms, 0.000_001)) + 55) / 45)))
        }
        queue.async { [self] in convert(copy) }
    }
    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: convertedFrames, timescale: Int32(target.sampleRate))))
        convertedFrames += Int64(buffer.frameLength)
    }
    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter else { yield(input); return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            failure(SpeechRecognitionFailure.message("无法分配识别音频缓冲区。")); return
        }
        var supplied = false, error: NSError?
        let state = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if state != .error { yield(output) }
        else { failure(error ?? SpeechRecognitionFailure.message("麦克风音频转换失败。") as NSError) }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }; accepting = false
        queue.async { [self] in
            if let converter {
                for _ in 0..<8 {
                    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { break }
                    var error: NSError?
                    let state = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
                    yield(output)
                    if state == .endOfStream || state == .error || output.frameLength == 0 { break }
                }
            }
            continuation.finish()
        }
    }
}
#endif
