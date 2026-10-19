import AVFoundation
import Combine
import Foundation

/// One bounded, memory-only utterance. The helper owns actual ASR and LLM inference;
/// this backend never invents word timestamps for text returned by those models.
@MainActor
final class LocalAISpeechCapture: ObservableObject, SpeechInput {
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var originalTranscript: String?
    @Published private(set) var cleanupApplied = false
    @Published private(set) var cleanupIssue: String?
    @Published private(set) var status = "按 R，说出这一刻的感想。"
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var authorizationGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var hasFinalResult = false
    @Published private(set) var lastIssue: String?
    @Published private(set) var isRecognizingFile = false
    let hasFinalTiming = false
    let wordSegments: [SpeechSegment] = []
    let segments: [SpeechSegment] = []
    var onUnexpectedStop: ((String) -> Void)?
    private enum Phase { case idle, preparing, recording, finishing, file }
    private var phase: Phase = .idle
    private var sessionID: UUID?
    private var options = SpeechRecognitionOptions(mode: .localAI)
    private let service: LocalAIVoiceService
    private let maximumDuration: Double
    private var engine: AVAudioEngine?
    private var collector: LocalAIMemoryAudioCollector?
    private var task: Task<Void, Never>?
    private var statusObservation: AnyCancellable?
    private var configurationObserver: NSObjectProtocol?
    private var stopWaiters: [CheckedContinuation<String, Never>] = []
    private var automaticallyFinishing = false
    private var activeContext: [String] = []
    private var activeCloudCleanup = false
    private let cloudCleanupEnabled: () -> Bool
    private let cloudCleaner: @Sendable (String, [String]) async throws -> String

    init(service: LocalAIVoiceService? = nil, maximumDuration: Double = 120,
         cloudCleanupEnabled: @escaping () -> Bool = { DeepSeekSettings.cleanupEnabled },
         cloudCleaner: @escaping @Sendable (String, [String]) async throws -> String = { text, terms in
             let result = try await DeepSeekTextService.shared.clean(text: text, context: terms)
             return try SpeechTextCleaner.validateResult(result, original: text, protectedTerms: terms, allowPhoneticCorrections: true)
         }) {
        self.service = service ?? .shared; self.maximumDuration = max(0.01, min(120, maximumDuration))
        self.cloudCleanupEnabled = cloudCleanupEnabled; self.cloudCleaner = cloudCleaner
        statusObservation = self.service.$statusMessage.sink { [weak self] value in
            guard let self, self.sessionID != nil, self.phase == .preparing || self.phase == .finishing || self.phase == .file else { return }
            self.status = value
        }
    }
    func configure(options: SpeechRecognitionOptions) { self.options = options }
    private func begin(phase: Phase) throws -> UUID {
        guard self.phase == .idle else { throw SpeechRecognitionFailure.message("上一段本地 AI 口述尚未结束。") }
        guard service.isReady else { throw SpeechRecognitionFailure.message(service.availabilityMessage) }
        let id = UUID(); sessionID = id; self.phase = phase; activeContext = options.contextualStrings
        activeCloudCleanup = cloudCleanupEnabled()
        transcript = ""; originalTranscript = nil; cleanupApplied = false; cleanupIssue = nil
        hasFinalResult = false; lastIssue = nil; audioLevel = 0; automaticallyFinishing = false
        return id
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation(); guard sessionID == id else { throw CancellationError() }
    }

    func start() async throws {
        let id = try begin(phase: .preparing)
        status = "正在准备本地 AI 口述…"
        do {
            try await service.warmUp(); try check(id)
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
                throw SpeechRecognitionFailure.message("请从“映述.app”启动，以启用麦克风权限。")
            }
            var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            try check(id); authorizationGranted = granted
            guard granted else { throw SpeechRecognitionFailure.message("请在“系统设置 → 隐私与安全性 → 麦克风”中允许映述。") }
            let engine = AVAudioEngine(), input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechRecognitionFailure.message("没有可用的麦克风输入。") }
            let collector = try makeCollector(format: format, id: id)
            self.engine = engine; self.collector = collector
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in collector.append(buffer) }
            collector.tapInstalled = true
            engine.prepare(); try engine.start()
            phase = .recording; isRecording = true
            status = "画面已暂停 · 本地 AI 正在收听，R 结束后自动识别整理。"
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id, self.phase == .recording else { return }
                    self.beginFinishing(id: id, automatic: true)
                }
            }
        } catch {
            if sessionID == id { fail(error, id: id, unexpected: false) }
            throw error
        }
    }

    private func makeCollector(format: AVAudioFormat, id: UUID) throws -> LocalAIMemoryAudioCollector {
        try LocalAIMemoryAudioCollector(inputFormat: format, maximumDuration: maximumDuration, meter: { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id, self.phase == .recording else { return }; self.audioLevel = level
            }
        }, onLimit: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id, self.phase == .recording else { return }
                self.beginFinishing(id: id, automatic: true)
            }
        }, failure: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }; self.fail(error, id: id, unexpected: self.isRecording)
            }
        })
    }

    func stop() async -> String {
        guard let id = sessionID else { return transcript }
        if phase == .preparing { cancel(); return "" }
        if phase == .file { return transcript }
        // If automatic limit handling is already running, the explicit user action takes
        // ownership of committing its result. It does not submit another helper request.
        automaticallyFinishing = false; isRecording = false
        if phase == .recording { beginFinishing(id: id, automatic: false) }
        guard sessionID == id else { return transcript }
        return await withCheckedContinuation { stopWaiters.append($0) }
    }
    private func beginFinishing(id: UUID, automatic: Bool) {
        guard sessionID == id, phase == .recording else { return }
        phase = .finishing; automaticallyFinishing = automatic
        // During an automatic finish this stays true solely as the existing AppModel's
        // recording lock. Actual audio input is stopped now; R can await the same result.
        isRecording = automatic; audioLevel = 0
        status = automatic ? "口述已达到上限，正在本地 AI 识别整理…" : "本地 AI 正在识别整理这一段口述…"
        stopAudio()
        guard let collector else { fail(SpeechRecognitionFailure.message("没有收到口述音频。"), id: id, unexpected: automatic); return }
        let context = activeContext
        task = Task { [weak self] in
            do {
                let audio = try await collector.finish()
                guard let self else { return }; try self.check(id)
                guard audio.hasAudibleInput else {
                    self.end(status: "没有听到清晰语音，请重试或使用“写一句”。", unexpected: self.automaticallyFinishing); return
                }
                let result = try await self.service.transcribe(wav: audio.wav, context: context, cleanup: !self.activeCloudCleanup)
                try self.check(id); self.apply(result)
                try await self.refineWithDeepSeekIfEnabled(id: id, context: context)
                self.end(status: self.cleanupIssue ?? "AI 识别整理完成，原稿已保留。", unexpected: self.automaticallyFinishing)
            } catch {
                guard let self, self.sessionID == id else { return }; self.fail(error, id: id, unexpected: self.automaticallyFinishing)
            }
        }
    }
    private func apply(_ result: LocalAIVoiceResult) {
        transcript = result.text; originalTranscript = result.originalText
        cleanupApplied = result.cleanupApplied; cleanupIssue = result.cleanupIssue; hasFinalResult = true
    }
    private func refineWithDeepSeekIfEnabled(id: UUID, context: [String]) async throws {
        guard activeCloudCleanup, !transcript.isEmpty else { return }
        let raw = originalTranscript ?? transcript
        // Preserve the completed recognition immediately, including if termination
        // reaches its grace limit while the network request is still pending.
        transcript = raw; originalTranscript = raw; cleanupApplied = false; cleanupIssue = nil
        status = "语音已在本机识别，DeepSeek 正在整理这句话…"
        do {
            let cleaned = try await cloudCleaner(raw, context)
            try check(id)
            transcript = cleaned; cleanupApplied = true
        } catch {
            try check(id)
            transcript = raw; cleanupApplied = false
            cleanupIssue = "DeepSeek 整理未采用，已保留识别原稿：\(error.localizedDescription)"
        }
    }
    private func stopAudio() {
        engine?.stop()
        if collector?.tapInstalled == true { engine?.inputNode.removeTap(onBus: 0); collector?.tapInstalled = false }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; configurationObserver = nil
    }
    private func fail(_ error: Error, id: UUID, unexpected: Bool) {
        guard sessionID == id else { return }
        let message = error is CancellationError ? "口述已取消。" : "本地 AI 口述未完成：\(error.localizedDescription)"
        if !(error is CancellationError) { lastIssue = message }
        end(status: message, unexpected: unexpected)
    }
    private func end(status: String, unexpected: Bool) {
        sessionID = nil; phase = .idle; automaticallyFinishing = false
        stopAudio(); engine = nil; collector = nil; task = nil
        isRecording = false; isRecognizingFile = false; audioLevel = 0; self.status = status
        let text = transcript, waiters = stopWaiters; stopWaiters = []; waiters.forEach { $0.resume(returning: text) }
        if unexpected { onUnexpectedStop?(text) }
    }
    func cancel() {
        sessionID = nil; task?.cancel(); task = nil
        stopAudio(); collector?.cancel(); collector = nil; engine = nil
        service.cancelCurrentRequest()
        transcript = ""; originalTranscript = nil; cleanupApplied = false; cleanupIssue = nil; hasFinalResult = false
        end(status: "口述已取消。", unexpected: false)
    }

    /// Runs the same local models against a chosen file without opening a microphone.
    func transcribeFile(url: URL, requireOnDevice: Bool? = nil) async throws -> String {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw SpeechRecognitionFailure.message("测试音频不存在或无法读取。") }
        let id = try begin(phase: .file); isRecognizingFile = true
        return try await withTaskCancellationHandler(operation: {
            do {
                try await service.warmUp(); try check(id)
                let file = try AVAudioFile(forReading: url)
                let collector = try LocalAIMemoryAudioCollector(inputFormat: file.processingFormat, maximumDuration: maximumDuration)
                self.collector = collector
                let audio = try await Task.detached(priority: .userInitiated) {
                    var batches = 0
                    while file.framePosition < file.length {
                        try Task.checkCancellation()
                        guard !collector.wasCancelled else { throw CancellationError() }
                        guard Double(file.framePosition) / file.processingFormat.sampleRate < 120 else { throw SpeechRecognitionFailure.message("语音自检音频不能超过120秒。") }
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw SpeechRecognitionFailure.message("无法读取测试音频。") }
                        try file.read(into: buffer); collector.append(buffer)
                        batches += 1; if batches % 8 == 0 { await collector.drain() }
                    }
                    return try await collector.finish()
                }.value
                try check(id)
                guard audio.hasAudibleInput else { throw SpeechRecognitionFailure.message("这段测试音频没有可识别的人声。") }
                let result = try await service.transcribe(wav: audio.wav, context: activeContext, cleanup: !activeCloudCleanup)
                try check(id); apply(result)
                try await refineWithDeepSeekIfEnabled(id: id, context: activeContext)
                let text = transcript
                end(status: cleanupIssue ?? "AI 语音自检完成。", unexpected: false)
                return text
            } catch { if sessionID == id { fail(error, id: id, unexpected: false) }; throw error }
        }, onCancel: { [weak self] in Task { @MainActor [weak self] in if self?.sessionID == id { self?.cancel() } } })
    }

    #if LOCAL_AI_VOICE_TESTS
    /// Tests inject generated PCM, rather than requesting microphone permission.
    func beginBufferedCaptureForTesting(format: AVAudioFormat) throws {
        let id = try begin(phase: .recording); collector = try makeCollector(format: format, id: id)
        isRecording = true; status = "测试注入口述。"
    }
    func appendPCMForTesting(_ buffer: AVAudioPCMBuffer) { collector?.append(buffer) }
    #endif
}

struct LocalAIMemoryAudio: Sendable {
    let wav: Data
    let hasAudibleInput: Bool
}

/// Converts on a serial queue, retaining at most 120 seconds / 4 MiB of output PCM.
/// Pending input buffers are bounded too; overload reports an error rather than dropping words.
final class LocalAIMemoryAudioCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "YingShu.local-ai-pcm", qos: .userInitiated)
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private let maximumBytes: Int
    private let maximumDuration: Double
    private let meter: @Sendable (Float) -> Void
    private let onLimit: @Sendable () -> Void
    private let failure: @Sendable (Error) -> Void
    private var acceptsAudio = true
    private var cancellationRequested = false
    private var audibleSeconds: Double = 0
    private var inputSeconds: Double = 0
    private var pendingBuffers = 0
    private var lastMeter = 0.0
    private var pcm = Data()
    private var conversionError: Error?
    private var completed: LocalAIMemoryAudio?
    private var cancelled = false
    private var limitReported = false
    var tapInstalled = false // Main actor owns this flag.

    init(inputFormat: AVAudioFormat, maximumDuration: Double = 120,
         meter: @escaping @Sendable (Float) -> Void = { _ in }, onLimit: @escaping @Sendable () -> Void = {},
         failure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: target) else { throw SpeechRecognitionFailure.message("无法准备本地 AI 音频格式。") }
        self.converter = converter; converter.downmix = true
        self.maximumDuration = max(0.01, min(120, maximumDuration))
        self.maximumBytes = min(LocalAIVoiceService.maximumWAVBytes - 44, Int(self.maximumDuration * 32_000) / 2 * 2)
        self.meter = meter; self.onLimit = onLimit; self.failure = failure
    }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard acceptsAudio, input.frameLength > 0 else { return }
        guard pendingBuffers < 64 else {
            acceptsAudio = false; failure(SpeechRecognitionFailure.message("音频处理来不及跟上麦克风，请结束后重试。")); return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return }
        copy.frameLength = input.frameLength
        for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList)), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
            if let source = source.mData, let destinationData = destination.mData { memcpy(destinationData, source, Int(destination.mDataByteSize)) }
        }
        let rms = SpeechAudioMeasurement.rms(input)
        if rms > SpeechAudioMeasurement.minimumAudibleRMS { audibleSeconds += Double(input.frameLength) / input.format.sampleRate }
        inputSeconds += Double(input.frameLength) / input.format.sampleRate
        let reachedLimit = inputSeconds >= maximumDuration
        if reachedLimit { acceptsAudio = false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeter >= 0.075 { lastMeter = now; meter(max(0, min(1, (20 * log10(max(rms, 0.000_001)) + 70) / 60))) }
        pendingBuffers += 1
        queue.async { [self] in
            defer { lock.lock(); pendingBuffers -= 1; lock.unlock() }
            guard !cancelled else { return }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16_000 / copy.format.sampleRate)) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let state = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return copy
            }
            if state == .error { conversionError = error ?? SpeechRecognitionFailure.message("本地 AI 音频转换失败。") as NSError; failure(conversionError!) }
            else { appendConverted(output) }
            // A resampler can retain a few frames until finish. Trigger from source
            // duration too, otherwise an exact 120s input could wait forever for a tail.
            if reachedLimit && !limitReported { limitReported = true; onLimit() }
        }
    }
    private func appendConverted(_ buffer: AVAudioPCMBuffer) {
        guard !cancelled, let samples = buffer.int16ChannelData else { return }
        let count = min(max(0, maximumBytes - pcm.count), Int(buffer.frameLength) * 2)
        if count > 0 { pcm.append(UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: count) }
        if pcm.count >= maximumBytes && !limitReported { limitReported = true; onLimit() }
    }
    var wasCancelled: Bool { lock.withLock { cancellationRequested } }
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    func finish() async throws -> LocalAIMemoryAudio {
        lock.withLock { acceptsAudio = false }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                if let completed { continuation.resume(returning: completed); return }
                if let conversionError { continuation.resume(throwing: conversionError); return }
                for _ in 0..<8 {
                    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { break }
                    var error: NSError?
                    let state = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
                    if state == .error { continuation.resume(throwing: error ?? SpeechRecognitionFailure.message("音频收尾转换失败。") as NSError); return }
                    appendConverted(output)
                    if state == .endOfStream || output.frameLength == 0 { break }
                }
                lock.lock(); let audible = audibleSeconds >= SpeechAudioMeasurement.minimumAudibleSeconds; lock.unlock()
                let value = LocalAIMemoryAudio(wav: Self.wav(pcm), hasAudibleInput: audible)
                completed = value; pcm = Data(); continuation.resume(returning: value)
            }
        }
    }
    func cancel() {
        lock.withLock { acceptsAudio = false; cancellationRequested = true }
        queue.async { [self] in cancelled = true; pcm = Data(); completed = nil }
    }
    static func wav(_ pcm: Data) -> Data {
        var result = Data()
        func number<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        result.append(Data("RIFF".utf8)); number(UInt32(pcm.count + 36)); result.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16))
        result.append(Data("data".utf8)); number(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
