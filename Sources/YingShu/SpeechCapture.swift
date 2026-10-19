import AVFoundation
import Combine
import Foundation
import Speech

/// Times are relative to the start of this recognition's audio, never the video timeline.
/// utf16Range addresses `SpeechCapture.transcript`, just like SFTranscriptionSegment.substringRange.
struct SpeechSegment: Equatable, Sendable {
    var text: String
    var timestamp: TimeInterval
    var duration: TimeInterval
    var utf16Range: NSRange = NSRange(location: 0, length: 0)
    var end: TimeInterval { timestamp + duration }
}

/// A short dictation session. This app never writes microphone buffers to disk.
@MainActor
final class SpeechCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = "按 R，说出这一刻的感想。"
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var authorizationGranted = false
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var wordSegments: [SpeechSegment] = []
    @Published private(set) var hasFinalTiming = false
    @Published private(set) var hasFinalResult = false
    @Published private(set) var lastIssue: String?
    @Published private(set) var isRecognizingFile = false

    /// Called only if the recognizer ends a session before the user presses stop.
    /// The payload is the latest recognized text, which may be empty.
    var onUnexpectedStop: ((String) -> Void)?

    private enum Phase { case idle, authorizing, recording, finishing, transcribingFile }
    private var phase: Phase = .idle
    private var options = SpeechRecognitionOptions()

    func configure(options: SpeechRecognitionOptions) { self.options = options }
    private var sessionID: UUID?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var inputBridge: SpeechAudioInput?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var finishDeadline: Task<Void, Never>?
    private var stopWaiters: [CheckedContinuation<String, Never>] = []
    private var fileWaiter: CheckedContinuation<String, Error>?

    init() {
        authorizationGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() async throws {
        guard phase == .idle else { throw CaptureError.message("上一句口述尚未结束，请稍候。") }
        let sessionOptions = options
        let id = UUID()
        sessionID = id
        phase = .authorizing
        resetTranscript()
        audioLevel = 0
        status = "正在准备中文语音输入…"

        do {
            try await requestPermissions(session: id, needsMicrophone: true)
            try checkActiveSession(id)
            let recognizer = try await availableRecognizer(session: id)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.message("没有可用的麦克风，请在系统设置中选择输入设备。")
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.contextualStrings = sessionOptions.contextualStrings
            request.addsPunctuation = true
            // Do not silently fall back to a server if an available local recognizer fails.
            if sessionOptions.mode == .localFirst && !recognizer.supportsOnDeviceRecognition {
                throw CaptureError.message("此 Mac 暂不支持本机中文识别。请在语音设置中明确选择 Apple 系统服务后重试。")
            }
            let usesOnDeviceRecognition = sessionOptions.mode == .localFirst
            request.requiresOnDeviceRecognition = usesOnDeviceRecognition
            let bridge = SpeechAudioInput(request: request)
            self.recognizer = recognizer
            self.request = request
            self.engine = engine
            self.inputBridge = bridge

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcription = result?.bestTranscription
                let isFinal = result?.isFinal ?? false
                let failure = error.map { $0 as NSError }
                Task { @MainActor [weak self] in
                    self?.receive(transcription: transcription, isFinal: isFinal, error: failure, session: id)
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if let level = bridge.append(buffer) {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == id, self.phase == .recording else { return }
                        self.audioLevel = level
                    }
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            phase = .recording
            isRecording = true
            status = usesOnDeviceRecognition
                ? "正在听 · 本机中文识别，不保存本地录音。"
                : "正在听 · Apple 中文识别可能需要联网，录音不会保存到项目。"
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id, self.phase == .recording else { return }
                    self.finishSession(status: "麦克风设置发生变化，口述已停止；已保留识别文字。", unexpected: true)
                }
            }
        } catch {
            // A canceled permission dialog must not tear down a later session.
            if sessionID == id {
                let message = error is CancellationError ? "口述已取消。" : error.localizedDescription
                if !(error is CancellationError) { lastIssue = message }
                finishSession(status: message)
            }
            throw error
        }
    }

    /// Ends microphone input immediately, then gives Speech a bounded window for the final words.
    func stop() async -> String {
        guard phase != .idle else { return transcript }
        if phase == .authorizing { cancel(); return "" }
        if phase == .transcribingFile { return transcript }
        if phase == .recording {
            phase = .finishing
            isRecording = false
            audioLevel = 0
            status = "正在确认最后几个字…"
            stopAudioInput()
            let id = sessionID
            finishDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard let self, self.sessionID == id, self.phase == .finishing else { return }
                let message = self.transcript.isEmpty
                    ? "系统没有及时返回文字，请检查中文听写资源后重试。"
                    : "已保留临时识别文字；系统未及时确认，末尾和时间位置可能不完整，请检查。"
                self.lastIssue = message
                self.finishSession(status: message)
            }
        }
        return await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func cancel() {
        resetTranscript()
        finishSession(status: "口述已取消。", error: CancellationError())
    }

    /// Exercises the actual Chinese recognizer in the app's normal Speech permission context.
    /// It reads only the chosen local file, never opens or requests access to the microphone.
    /// The default uses the same local-first policy as live dictation. Set requireOnDevice to
    /// false only for an explicitly chosen Apple system-service diagnostic.
    func transcribeFile(url: URL, requireOnDevice: Bool? = nil) async throws -> String {
        guard phase == .idle else { throw CaptureError.message("请先结束当前口述，再运行语音识别自检。") }
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw CaptureError.message("自检音频不存在或无法读取，请选择本地音频文件。")
        }
        let sessionOptions = options
        let id = UUID()
        sessionID = id
        phase = .authorizing
        resetTranscript()
        status = "正在准备中文语音识别自检，不会使用麦克风…"
        do {
            try await requestPermissions(session: id, needsMicrophone: false)
            let recognizer = try await availableRecognizer(session: id)
            try checkActiveSession(id)
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.contextualStrings = sessionOptions.contextualStrings
            request.addsPunctuation = true
            let usesLocal = requireOnDevice ?? (sessionOptions.mode == .localFirst && recognizer.supportsOnDeviceRecognition)
            guard !usesLocal || recognizer.supportsOnDeviceRecognition else {
                throw CaptureError.message("此 Mac 当前不支持本机中文识别。可选择 Apple 系统联网识别进行自检。")
            }
            request.requiresOnDeviceRecognition = usesLocal
            self.recognizer = recognizer
            self.request = request
            phase = .transcribingFile
            isRecognizingFile = true
            status = usesLocal ? "正在自检本机中文识别，不会使用麦克风…" : "正在自检 Apple 系统中文识别，可能通过网络处理此测试音频…"
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    fileWaiter = continuation
                    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                        let transcription = result?.bestTranscription
                        let isFinal = result?.isFinal ?? false
                        let failure = error.map { $0 as NSError }
                        Task { @MainActor [weak self] in
                            self?.receive(transcription: transcription, isFinal: isFinal, error: failure, session: id)
                        }
                    }
                    finishDeadline = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                        guard let self, self.sessionID == id, self.phase == .transcribingFile else { return }
                        let message = "中文识别自检超时。请确认中文听写资源已下载、语音权限已允许，再重试。"
                        self.lastIssue = message
                        self.finishSession(status: message, error: CaptureError.message(message))
                    }
                }
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.finishSession(status: "已取消语音识别自检。", error: CancellationError())
                }
            })
        } catch {
            if sessionID == id {
                let message = error is CancellationError ? "已取消语音识别自检。" : error.localizedDescription
                if !(error is CancellationError) { lastIssue = message }
                finishSession(status: message, error: error)
            }
            throw error
        }
    }

    private func resetTranscript() {
        transcript = ""
        segments = []
        wordSegments = []
        hasFinalTiming = false
        hasFinalResult = false
        lastIssue = nil
    }

    private var completionStatus: String {
        transcript.isEmpty ? "没有听到清晰的语音，请重试或使用“写一句”。" : "文字已就绪，可继续说下一句。"
    }

    private func checkActiveSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
    }

    private func availableRecognizer(session id: UUID) async throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            throw CaptureError.message("此 Mac 暂不支持中文语音识别。你仍可使用“写一句”。")
        }
        // Immediately after the first authorization, Speech's service may take a moment to connect.
        for _ in 0..<20 {
            try checkActiveSession(id)
            if recognizer.isAvailable { return recognizer }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let detail = options.mode == .localFirst
            ? "本机中文识别暂不可用。请在“系统设置 → 键盘 → 听写”中确认中文（普通话）资源已下载，或在映述语音设置中明确选择 Apple 系统服务。"
            : "Apple 系统中文识别暂不可用。请确认中文听写可用，并检查网络后重试。"
        throw CaptureError.message(detail)
    }

    private func requestPermissions(session id: UUID, needsMicrophone: Bool) async throws {
        try checkActiveSession(id)
        // Missing usage descriptions make Apple's authorization API raise an exception.
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") is String,
              !needsMicrophone || Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
            throw CaptureError.message("请从“映述.app”启动，以启用系统麦克风与语音权限。")
        }
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            status = "请允许中文语音识别；系统可能使用 Apple 的语音服务。"
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        try checkActiveSession(id)
        switch speechStatus {
        case .authorized: break
        case .denied:
            authorizationGranted = false
            throw CaptureError.message("语音识别权限未开启。请在“系统设置 → 隐私与安全性 → 语音识别”中允许映述。")
        case .restricted:
            authorizationGranted = false
            throw CaptureError.message("此 Mac 的语音识别受到系统限制。你仍可使用“写一句”添加文字。")
        default:
            authorizationGranted = false
            throw CaptureError.message("尚未获得语音识别权限，请重试。")
        }
        try checkActiveSession(id)
        if !needsMicrophone {
            authorizationGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            return
        }
        var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            status = "请允许访问麦克风，声音用于文字识别，不会加入导出视频。"
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try checkActiveSession(id)
            microphoneStatus = granted ? .authorized : .denied
        }
        guard microphoneStatus == .authorized else {
            authorizationGranted = false
            throw CaptureError.message("麦克风权限未开启。请在“系统设置 → 隐私与安全性 → 麦克风”中允许映述。")
        }
        authorizationGranted = true
    }

    private func receive(transcription: SFTranscription?, isFinal: Bool, error: NSError?, session id: UUID) {
        guard sessionID == id, phase == .recording || phase == .finishing || phase == .transcribingFile else { return }
        let isFile = phase == .transcribingFile
        // Never turn a recognizer's result from all-zero/inaudible input into a caption.
        if isFile || inputBridge?.hasAudibleInput == true, let transcription {
            let cleaned = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty final callback must not erase a useful partial result.
            if !cleaned.isEmpty {
                transcript = cleaned
                wordSegments = Self.timedWords(from: transcription, transcript: cleaned)
                segments = Self.shortPhrases(from: wordSegments, transcript: cleaned)
                hasFinalResult = isFinal
                hasFinalTiming = isFinal && !wordSegments.isEmpty && wordSegments.allSatisfy { $0.duration > 0 }
            }
        }
        if isFinal {
            if isFile && transcript.isEmpty {
                let message = "中文识别自检完成，但没有识别到文字。请检查所选测试音频。"
                lastIssue = message
                finishSession(status: message, error: CaptureError.message(message))
            } else {
                let fileStatus = hasFinalTiming
                    ? "中文识别自检通过，已获得真实文字与时间分段。"
                    : "中文识别自检已获得真实文字；系统没有返回完整的时间分段。"
                finishSession(status: isFile ? fileStatus : completionStatus, unexpected: phase == .recording)
            }
        } else if let error {
            let message = Self.explanation(for: error) + (transcript.isEmpty ? "" : " 已保留已识别文字，末尾可能不完整。")
            lastIssue = message
            finishSession(status: message, unexpected: phase == .recording, error: isFile ? CaptureError.message(message) : nil)
        }
    }

    /// Apple's ranges are UTF-16 offsets. Include the gap before the next word in this word,
    /// which preserves commas, punctuation, and English spaces without inventing any text.
    private static func timedWords(from transcription: SFTranscription, transcript: String) -> [SpeechSegment] {
        let fullText = transcription.formattedString as NSString
        let cleaned = transcript as NSString
        let trimOffset = fullText.range(of: transcript).location
        guard trimOffset != NSNotFound else { return [] }
        let source = transcription.segments.filter {
            $0.substringRange.location != NSNotFound && $0.substringRange.length > 0
                && $0.timestamp.isFinite && $0.timestamp >= 0 && $0.duration.isFinite && $0.duration >= 0
        }
        return source.enumerated().compactMap { index, segment in
            let lower = max(0, min(cleaned.length, segment.substringRange.location - trimOffset))
            let nextLower = index + 1 < source.count ? source[index + 1].substringRange.location - trimOffset : cleaned.length
            let rawEnd = segment.substringRange.location - trimOffset + segment.substringRange.length
            let upper = max(lower, min(cleaned.length, max(rawEnd, nextLower)))
            let range = NSRange(location: index == 0 ? 0 : lower, length: upper - (index == 0 ? 0 : lower))
            guard range.length > 0 else { return nil }
            return SpeechSegment(text: cleaned.substring(with: range), timestamp: segment.timestamp, duration: segment.duration, utf16Range: range)
        }
    }

    /// Keeps true word timing available while offering readable phrases to simple clients.
    static func shortPhrases(from words: [SpeechSegment], transcript: String) -> [SpeechSegment] {
        let text = transcript as NSString
        var output: [SpeechSegment] = []
        var group: [SpeechSegment] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let start = first.utf16Range.location
            let end = NSMaxRange(last.utf16Range)
            if start >= 0, end >= start, end <= text.length {
                let range = NSRange(location: start, length: end - start)
                output.append(SpeechSegment(text: text.substring(with: range), timestamp: first.timestamp,
                                            duration: max(0, group.map(\.end).max()! - first.timestamp), utf16Range: range))
            }
            group.removeAll()
        }
        for word in words {
            if let first = group.first, let previous = group.last {
                let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let punctuation = previousText.last.map { "，。！？；：,.!?;:\n".contains($0) } ?? false
                let characters = NSMaxRange(word.utf16Range) - first.utf16Range.location
                if punctuation || word.timestamp - previous.end >= 0.55 || characters > 24 || word.end - first.timestamp > 4.5 { flush() }
            }
            group.append(word)
        }
        flush()
        return output
    }

    /// Error domains/codes below follow Apple's SFSpeechRecognitionTask.error reference.
    private static func explanation(for error: NSError) -> String {
        let code = "（\(error.domain) \(error.code)）"
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 102):
            return "本机中文语音资源尚未就绪。请在“系统设置 → 键盘 → 听写”中添加中文（普通话），保持联网并等待资源下载后重试。\(code)"
        case ("kLSRErrorDomain", 201):
            return "系统的 Siri 或听写处于关闭状态。请在“系统设置 → 键盘 → 听写”中开启中文听写后重试。\(code)"
        case ("kLSRErrorDomain", 300):
            return "系统未能启动中文识别。请确认中文听写资源已就绪，稍后重试。\(code)"
        case ("kAFAssistantErrorDomain", 1100):
            return "系统中上一项语音识别尚未释放，请稍候再开始。\(code)"
        case ("kAFAssistantErrorDomain", 1101), ("kAFAssistantErrorDomain", 1107):
            return "系统语音识别进程中断。请重试；若反复出现，请检查中文听写是否可正常使用。\(code)"
        case ("kAFAssistantErrorDomain", 1110):
            return "没有听到清晰的中文语音，请重试或使用“写一句”。"
        case ("kAFAssistantErrorDomain", 1700):
            return "系统未授权本次识别。请在“系统设置 → 隐私与安全性 → 语音识别”中允许映述。\(code)"
        case (NSURLErrorDomain, _):
            return "Apple 语音服务的网络连接未完成，请检查网络后重试。\(code)"
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain != error.domain || underlying.code != error.code {
                return explanation(for: underlying)
            }
            return "中文语音识别未完成，请重试。\(code)"
        }
    }

    private func stopAudioInput() {
        engine?.stop()
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        inputBridge?.endAudio()
    }

    private func finishSession(status message: String, unexpected: Bool = false, error: Error? = nil) {
        // Invalidate first: cancellation and endAudio can themselves produce callbacks.
        sessionID = nil
        phase = .idle
        isRecording = false
        isRecognizingFile = false
        finishDeadline?.cancel()
        finishDeadline = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        stopAudioInput()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        engine = nil
        inputBridge = nil
        audioLevel = 0
        status = message
        let finalText = transcript
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: finalText) }
        let fileCompletion = fileWaiter
        fileWaiter = nil
        if let error { fileCompletion?.resume(throwing: error) } else { fileCompletion?.resume(returning: finalText) }
        if unexpected { onUnexpectedStop?(finalText) }
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}

/// Serializes tap appends with endAudio, without touching main-actor state on the audio thread.
private final class SpeechAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var acceptsAudio = true
    private var audibleSeconds: Double = 0
    private var lastMeterUpdate = 0.0

    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    var hasAudibleInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return audibleSeconds >= SpeechAudioMeasurement.minimumAudibleSeconds
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard acceptsAudio, buffer.frameLength > 0 else { return nil }
        request.append(buffer)
        let rms = SpeechAudioMeasurement.rms(buffer)
        if rms > SpeechAudioMeasurement.minimumAudibleRMS, buffer.format.sampleRate > 0 {
            audibleSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeterUpdate >= 0.075 else { return nil }
        lastMeterUpdate = now
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 55) / 45))
    }

    func endAudio() {
        lock.lock(); defer { lock.unlock() }
        guard acceptsAudio else { return }
        acceptsAudio = false
        request.endAudio()
    }
}


/// This is a near-zero-input guard, not voice activity detection or a noise classifier.
/// A quiet but real recognition result must not be rejected just for having low gain.
enum SpeechAudioMeasurement {
    static let minimumAudibleRMS: Float = 0.0001
    static let minimumAudibleSeconds: Double = 0.035

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            // Interleaved PCM exposes one data pointer; the channels are sample offsets.
            let pointer = buffer.format.isInterleaved ? 0 : channel
            let offset = buffer.format.isInterleaved ? channel : 0
            var squaredSum: Float = 0
            for frame in 0..<Int(buffer.frameLength) {
                let index = frame * buffer.stride + offset
                let sample: Float
                if let data = buffer.floatChannelData { sample = data[pointer][index] }
                else if let data = buffer.int16ChannelData { sample = Float(data[pointer][index]) / 32768 }
                else if let data = buffer.int32ChannelData { sample = Float(data[pointer][index]) / 2_147_483_648 }
                else { sample = 0 }
                squaredSum += sample * sample
            }
            rms = max(rms, sqrt(squaredSum / Float(buffer.frameLength)))
        }
        return rms
    }
}
