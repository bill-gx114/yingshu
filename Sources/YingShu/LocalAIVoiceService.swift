import Combine
import Darwin
import Foundation

struct LocalAIAvailability: Sendable {
    let isReady: Bool
    let message: String
}

struct LocalAIVoiceMetrics: Equatable, Sendable {
    var asrSeconds: Double?
    var cleanupSeconds: Double?
}

enum LocalAICleanupIssueKind: String, Equatable, Sendable {
    case retainedOriginal = "retained_original"
    case generationFailed = "generation_failed"
}

struct LocalAIVoiceResult: Equatable, Sendable {
    let text: String
    let originalText: String
    let cleanupApplied: Bool
    let cleanupIssue: String?
    let metrics: LocalAIVoiceMetrics
    var cleanupIssueKind: LocalAICleanupIssueKind? = nil
}

/// Only this app-owned manifest may choose the runtime executable. Project documents and
/// model responses never supply command paths or command-line arguments.
@MainActor
final class LocalAIVoiceService: ObservableObject {
    static let shared = LocalAIVoiceService()
    nonisolated static let maximumWAVBytes = 4 * 1024 * 1024
    @Published private(set) var statusMessage = "本地 AI 尚未启动。"

    private struct RuntimeManifest: Decodable, Sendable {
        let pythonPath: String
        let asrModelPath: String
        let cleanupModelPath: String
        let asrModelID: String
        let cleanupModelID: String
        enum CodingKeys: String, CodingKey {
            case pythonPath = "python_path", asrModelPath = "asr_model_path"
            case cleanupModelPath = "cleanup_model_path", asrModelID = "asr_model_id", cleanupModelID = "cleanup_model_id"
        }
    }
    private struct Pending {
        let id: String
        let continuation: CheckedContinuation<LocalAIVoiceResult, Error>
    }
    private let manifestURL: URL
    private let workerURL: URL?
    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var generation: UUID?
    private var ready = false
    private var warmWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pending: Pending?
    private var startupDeadline: Task<Void, Never>?
    private var requestDeadline: Task<Void, Never>?
    private var idleDeadline: Task<Void, Never>?
    private var stderrTail = Data()
    private let writer = DispatchQueue(label: "YingShu.local-ai-stdin", qos: .userInitiated)

    nonisolated private static var defaultManifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("YingShu/AI Runtime/manifest.json")
    }
    nonisolated static var runtimeAvailability: LocalAIAvailability {
        do {
            let manifest = try loadManifest(at: defaultManifestURL, workerURL: Bundle.main.resourceURL?.appendingPathComponent("ai_voice_worker.py"))
            return LocalAIAvailability(isReady: true, message: "本地 AI 已准备：\(manifest.asrModelID) 识别，\(manifest.cleanupModelID) 整理，无需 API Key。")
        } catch { return LocalAIAvailability(isReady: false, message: "本地 AI 尚未准备完成：\(error.localizedDescription)") }
    }
    convenience init() {
        self.init(manifestURL: Self.defaultManifestURL,
                  workerURL: Bundle.main.resourceURL?.appendingPathComponent("ai_voice_worker.py"))
    }

    /// Explicit injection for the standalone protocol checks. Production uses shared and
    /// resolves the worker inside the signed app bundle, never from its working directory.
    init(manifestURL: URL, workerURL: URL?, startupTimeout: TimeInterval = 90,
         requestTimeout: TimeInterval = 180, idleTimeout: TimeInterval = 180) {
        self.manifestURL = manifestURL
        self.workerURL = workerURL
        self.startupTimeout = max(0.05, startupTimeout)
        self.requestTimeout = max(0.05, requestTimeout)
        self.idleTimeout = max(0.05, idleTimeout)
    }

    var isReady: Bool { (try? validatedManifest()) != nil }
    var availabilityMessage: String {
        do {
            let manifest = try validatedManifest()
            return "本地 AI 已准备：\(manifest.asrModelID) 识别，\(manifest.cleanupModelID) 整理，无需 API Key。"
        } catch { return "本地 AI 尚未准备完成：\(error.localizedDescription)" }
    }

    private func validatedManifest() throws -> RuntimeManifest { try Self.loadManifest(at: manifestURL, workerURL: workerURL) }
    nonisolated private static func loadManifest(at manifestURL: URL, workerURL: URL?) throws -> RuntimeManifest {
        let manager = FileManager.default
        guard manifestURL.isFileURL,
              let attributes = try? manager.attributesOfItem(atPath: manifestURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else {
            throw SpeechRecognitionFailure.message("请先完成本机模型与运行环境准备。")
        }
        guard manifest.pythonPath.hasPrefix("/"), manager.isExecutableFile(atPath: manifest.pythonPath) else {
            throw SpeechRecognitionFailure.message("Python 运行环境不存在或无法执行，请重新准备本地 AI。")
        }
        for (name, path) in [("语音识别", manifest.asrModelPath), ("文字整理", manifest.cleanupModelPath)] {
            guard path.hasPrefix("/") else { throw SpeechRecognitionFailure.message("\(name)模型路径无效。") }
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
                  manager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("config.json").path),
                  let files = try? manager.contentsOfDirectory(atPath: path),
                  files.contains(where: { $0.hasSuffix(".safetensors") }) else {
                throw SpeechRecognitionFailure.message("\(name)模型不完整，请等待准备完成。")
            }
        }
        guard let workerURL, workerURL.isFileURL, manager.isReadableFile(atPath: workerURL.path) else {
            throw SpeechRecognitionFailure.message("应用缺少本地 AI 识别组件，请重新安装映述。")
        }
        return manifest
    }

    /// Coalesces background warming and a simultaneous first recording into one process.
    func warmUp() async throws {
        try Task.checkCancellation()
        if ready, process?.isRunning == true { scheduleIdle(); return }
        _ = try validatedManifest()
        let token = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                warmWaiters[token] = continuation
                if generation == nil {
                    do { try launch() } catch { stopProcess(error: error, status: error.localizedDescription) }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.warmWaiters[token] != nil else { return }
                self.cancelCurrentRequest()
            }
        })
    }

    func transcribe(wav: Data, context: [String], cleanup: Bool) async throws -> LocalAIVoiceResult {
        guard wav.count >= 44, wav.count <= Self.maximumWAVBytes,
              wav.prefix(4) == Data("RIFF".utf8), wav.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw failure("口述音频无效或超过 4 MiB，请缩短这一段后重试。")
        }
        return try await send(action: "transcribe", fields: ["audio_base64": wav.base64EncodedString(), "cleanup": cleanup], context: context)
    }

    func clean(text: String, context: [String]) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 2_000 else {
            throw failure("请选择一段不超过2000字的文字再整理。")
        }
        let result = try await send(action: "clean", fields: ["text": text], context: context)
        if let issue = result.cleanupIssue {
            if result.cleanupIssueKind == .retainedOriginal {
                throw SpeechTextCleanupError.rejected(issue)
            }
            // Missing/unknown kinds from an older worker stay failures. Never
            // infer execution state from a localized human-readable message.
            throw failure(issue)
        }
        return result.text
    }

    private func send(action: String, fields: [String: Any], context: [String]) async throws -> LocalAIVoiceResult {
        try await warmUp()
        try Task.checkCancellation()
        guard pending == nil, let generation, let input, ready else { throw failure("本地 AI 正在处理另一段内容，请稍候。") }
        idleDeadline?.cancel(); idleDeadline = nil
        let id = UUID().uuidString
        var request = fields
        request["id"] = id; request["action"] = action
        var contextLength = 0
        request["context"] = SpeechRecognitionOptions(contextualStrings: context).contextualStrings.filter { term in
            guard contextLength + term.utf16.count <= 2000 else { return false }
            contextLength += term.utf16.count; return true
        }
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        statusMessage = action == "clean" ? "本地 AI 正在整理文字…" : "本地 AI 正在识别并整理这一段口述…"
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, continuation: continuation)
                requestDeadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(self?.requestTimeout ?? 180)) } catch { return }
                    guard let self, self.generation == generation, self.pending?.id == id else { return }
                    self.stopProcess(error: self.failure("本地 AI 处理超时，请重试或缩短这一段口述。"), status: "本地 AI 处理超时。")
                }
                // A large base64 request can fill a pipe; never block the main/audio thread.
                writer.async { [weak self] in
                    do { try input.write(contentsOf: payload) }
                    catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == generation, self.pending?.id == id else { return }
                            self.stopProcess(error: self.failure("无法向本地 AI 发送音频：\(error.localizedDescription)"), status: "本地 AI 通信中断。")
                        }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.pending?.id == id else { return }
                self.cancelCurrentRequest()
            }
        })
    }

    private func launch() throws {
        let manifest = try validatedManifest()
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let generation = UUID()
        self.generation = generation; self.ready = false; self.stderrTail = Data()
        process.executableURL = URL(fileURLWithPath: manifest.pythonPath)
        process.arguments = [workerURL!.path, "--manifest", manifestURL.path]
        // Prevent Python/MLX from fetching models. Their paths must already be complete.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        // A child may exit while the large audio request is being written. Suppress
        // SIGPIPE for this pipe only, so EPIPE becomes a recoverable communication error.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw failure("无法准备本地 AI 通信管道。")
        }
        self.process = process; self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading; self.diagnostics = stderr.fileHandleForReading
        statusMessage = "正在唤醒本地 AI，首次加载模型需要一些时间…"
        try process.run()
        // Blocking reads run off the main actor. Each complete line is dispatched FIFO;
        // EOF follows the final line, so process exit cannot discard its last response.
        let output = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                let data = Data(bytes.prefix(count))
                buffer.append(data)
                guard buffer.count <= 2 * 1024 * 1024 else {
                    DispatchQueue.main.async { [weak self] in self?.protocolFailure(generation: generation, message: "本地 AI 返回数据过大。") }; return
                }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in self?.receive(line, generation: generation) }
                }
            }
            if !buffer.isEmpty { DispatchQueue.main.async { [weak self] in self?.receive(buffer, generation: generation) } }
            try? output.close()
            DispatchQueue.main.async { [weak self] in self?.didCloseOutput(generation: generation) }
        }
        let diagnostics = stderr.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(diagnostics.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                let data = Data(bytes.prefix(count))
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 16_384 { self.stderrTail = self.stderrTail.suffix(16_384) }
                }
            }
            try? diagnostics.close()
        }
        startupDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.nanoseconds(self?.startupTimeout ?? 90)) } catch { return }
            guard let self, self.generation == generation, !self.ready else { return }
            self.stopProcess(error: self.failure("本地 AI 模型加载超时，请检查运行环境后重试。"), status: "本地 AI 加载超时。")
        }
    }

    private func receive(_ line: Data, generation: UUID) {
        guard self.generation == generation else { return }
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            protocolFailure(generation: generation, message: "本地 AI 返回了无效数据，请重新准备运行环境。"); return
        }
        if !ready {
            if object["status"] as? String == "ready" {
                ready = true; startupDeadline?.cancel(); startupDeadline = nil
                statusMessage = "本地 AI 已就绪。"
                let waiters = warmWaiters.values; warmWaiters = [:]; waiters.forEach { $0.resume() }
                scheduleIdle(); return
            }
            let error = object["error"] as? String ?? "本地 AI 未能完成模型加载。"
            stopProcess(error: failure(error), status: error); return
        }
        guard let pending, object["id"] as? String == pending.id else { return } // stale/duplicate replies are inert
        self.pending = nil; requestDeadline?.cancel(); requestDeadline = nil
        if object["ok"] as? Bool == true, let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           text.utf16.count <= 100_000 {
            let metrics = object["metrics"] as? [String: Any]
            let original = object["original_text"] as? String ?? text
            guard original.utf16.count <= 100_000 else {
                pending.continuation.resume(throwing: failure("本地 AI 返回的识别原稿过长。")); scheduleIdle(); return
            }
            let result = LocalAIVoiceResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), originalText: original,
                cleanupApplied: object["cleanup_applied"] as? Bool ?? false,
                cleanupIssue: object["cleanup_issue"] as? String,
                metrics: LocalAIVoiceMetrics(asrSeconds: Self.validSeconds(metrics?["asr_seconds"]), cleanupSeconds: Self.validSeconds(metrics?["cleanup_seconds"])),
                cleanupIssueKind: (object["cleanup_issue_kind"] as? String).flatMap(LocalAICleanupIssueKind.init(rawValue:)))
            if result.cleanupIssue == nil { statusMessage = "本地 AI 识别与整理完成。" }
            else if result.cleanupIssueKind == .retainedOriginal { statusMessage = "AI 已处理，建议未采用；识别原稿已保留。" }
            else { statusMessage = "识别原稿已保留；AI 整理未完成。" }
            pending.continuation.resume(returning: result)
        } else {
            let message = object["error"] as? String ?? "本地 AI 没有识别到清晰文字，请重试。"
            statusMessage = message; pending.continuation.resume(throwing: failure(message))
        }
        scheduleIdle()
    }

    private func didCloseOutput(generation: UUID) {
        guard self.generation == generation else { return }
        let detail = String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = detail.isEmpty ? "本地 AI 后台意外退出，请重试；若反复出现，请重新准备运行环境。" : "本地 AI 后台退出：\(String(detail.suffix(1200)))"
        stopProcess(error: failure(message), status: message)
    }
    private func protocolFailure(generation: UUID, message: String) {
        guard self.generation == generation else { return }
        stopProcess(error: failure(message), status: message)
    }
    private func scheduleIdle() {
        idleDeadline?.cancel()
        guard ready, pending == nil else { return }
        let generation = generation
        idleDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.nanoseconds(self?.idleTimeout ?? 180)) } catch { return }
            guard let self, self.generation == generation, self.pending == nil else { return }
            self.stopProcess(error: CancellationError(), status: "本地 AI 已休眠，下次使用时重新唤醒。")
        }
    }
    func cancelCurrentRequest() { stopProcess(error: CancellationError(), status: "已取消本地 AI 处理。") }
    private func stopProcess(error: Error, status: String) {
        generation = nil; ready = false
        startupDeadline?.cancel(); startupDeadline = nil; requestDeadline?.cancel(); requestDeadline = nil; idleDeadline?.cancel(); idleDeadline = nil
        let process = self.process; self.process = nil
        let previousInput = input; input = nil
        // Closing a handle with a blocked write can wait for that write's lock. Let
        // termination unblock it, and close on the same writer queue instead of the UI.
        writer.async { try? previousInput?.close() }
        // The blocking reader owns and closes each read handle after EOF. Closing it here
        // could race a read or a newly reused file descriptor during an immediate retry.
        output = nil; diagnostics = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        let waiters = warmWaiters.values; warmWaiters = [:]; waiters.forEach { $0.resume(throwing: error) }
        let pending = self.pending; self.pending = nil; pending?.continuation.resume(throwing: error)
        statusMessage = status
    }
    private func failure(_ message: String) -> SpeechRecognitionFailure { .message(message) }
    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(0.001, min(3600, seconds)) * 1_000_000_000) }
    private static func validSeconds(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }; return value.doubleValue
    }
}
