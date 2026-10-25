import AppKit
import AVFoundation
import Darwin
import Foundation

private actor CloudCleanupProbe {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var requests: [(String, [String])] = []
    func run(_ text: String, _ context: [String]) async -> String {
        requests.append((text, context))
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ text: String) { let pending = continuation; continuation = nil; pending?.resume(returning: text) }
}

@main struct LocalAIVoiceChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingShu-LocalAI-Checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = temporary.appendingPathComponent("fake_worker.py")
        try fakeWorker.write(to: worker, atomically: true, encoding: .utf8)
        let asr = temporary.appendingPathComponent("asr"), cleanup = temporary.appendingPathComponent("cleanup")
        for directory in [asr, cleanup] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
            try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        func service(_ mode: String = "normal", startup: Double = 2, request: Double = 2, idle: Double = 3) throws -> (LocalAIVoiceService, URL) {
            let base = temporary.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let log = base.appendingPathComponent("events.jsonl"), manifest = base.appendingPathComponent("manifest.json")
            let json: [String: Any] = ["python_path": "/usr/bin/python3", "asr_model_path": asr.path, "cleanup_model_path": cleanup.path,
                "asr_model_id": "test-asr", "cleanup_model_id": "test-llm", "test_mode": mode, "test_log": log.path]
            try JSONSerialization.data(withJSONObject: json).write(to: manifest)
            return (LocalAIVoiceService(manifestURL: manifest, workerURL: worker, startupTimeout: startup, requestTimeout: request, idleTimeout: idle), log)
        }
        func events(_ log: URL) -> [[String: Any]] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
        }
        func pcm(_ count: Int = 4096, value: Float = 0.2, rate: Double = 48_000) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count { buffer.floatChannelData![0][frame] = value }
            return buffer
        }
        let wave = LocalAIMemoryAudioCollector.wav(Data(repeating: 0, count: 3200))
        let (client, log) = try service()
        precondition(client.isReady)
        async let warmA: Void = client.warmUp()
        async let warmB: Void = client.warmUp()
        _ = try await (warmA, warmB)
        precondition(events(log).filter { $0["event"] as? String == "launch" }.count == 1, "Simultaneous warming must launch one process")
        let result = try await client.transcribe(wav: wave, context: ["熊本", "熊本"], cleanup: true)
        precondition(result.text == "今天去了海边，很开心。" && result.originalText == "今天呃去了海边海边，很开心")
        precondition(result.cleanupApplied && result.metrics.asrSeconds == 0.12 && result.metrics.cleanupSeconds == 0.08)
        let clean = try await client.clean(text: "这是原文", context: ["熊本"])
        precondition(clean == "这是整理后的文字。")
        precondition(events(log).filter { $0["event"] as? String == "request" }.count == 2)
        print("PASS real Process JSONL, coalesced warm-up, fragmented/stale replies, original/final text, cleanup metadata, and warm process reuse")

        let capture = LocalAISpeechCapture(service: client, cloudCleanupEnabled: { false })
        try capture.beginBufferedCaptureForTesting(format: pcm().format); capture.appendPCMForTesting(pcm())
        async let stoppedA = capture.stop()
        async let stoppedB = capture.stop()
        let (a, b) = await (stoppedA, stoppedB)
        precondition(a == b && a == result.text && capture.originalTranscript == result.originalText && capture.cleanupApplied)
        precondition(capture.wordSegments.isEmpty && !capture.hasFinalTiming && capture.hasFinalResult)
        let afterSpeech = events(log).filter { $0["action"] as? String == "transcribe" }.count
        precondition(afterSpeech == 2, "Two stop calls must submit only one new request")
        try capture.beginBufferedCaptureForTesting(format: pcm().format); capture.appendPCMForTesting(pcm(value: 0))
        let silence = await capture.stop()
        precondition(silence.isEmpty && !capture.hasFinalResult && events(log).filter { $0["action"] as? String == "transcribe" }.count == afterSpeech,
                     "All-zero audio must not invoke a generative recognizer")
        let beforeCancel = events(log).filter { $0["action"] as? String == "transcribe" }.count
        try capture.beginBufferedCaptureForTesting(format: pcm().format); capture.appendPCMForTesting(pcm())
        let abandonedCapture = Task { await capture.stop() }
        try await until { events(log).filter { $0["action"] as? String == "transcribe" }.count > beforeCancel }
        capture.cancel()
        try capture.beginBufferedCaptureForTesting(format: pcm().format); capture.appendPCMForTesting(pcm())
        let replacement = await capture.stop()
        let abandonedText = await abandonedCapture.value
        precondition(abandonedText.isEmpty && replacement == result.text && capture.transcript == replacement && capture.originalTranscript == result.originalText,
                     "A cancelled inference must not overwrite or cancel a replacement capture")
        print("PASS concurrent stop submits one inference, zero-input gate, no invented word timings, and cancelled/replacement session isolation")

        let automatic = LocalAISpeechCapture(service: client, maximumDuration: 0.05, cloudCleanupEnabled: { false })
        var automaticText: String?, automaticCalls = 0
        automatic.onUnexpectedStop = { automaticText = $0; automaticCalls += 1 }
        try automatic.beginBufferedCaptureForTesting(format: pcm().format); automatic.appendPCMForTesting(pcm())
        try await until { automaticText != nil }
        precondition(automaticText == result.text && automaticCalls == 1 && !automatic.isRecording)
        let limitPCM = pcm(16_000 * 121, rate: 16_000)
        let limit = try LocalAIMemoryAudioCollector(inputFormat: limitPCM.format)
        limit.append(limitPCM)
        let bounded = try await limit.finish()
        precondition(bounded.wav.count == 120 * 32_000 + 44 && bounded.wav.count < LocalAIVoiceService.maximumWAVBytes && bounded.hasAudibleInput)
        print("PASS automatic limit commits once and memory WAV is mono 16kHz Int16, capped at 120 seconds / less than 4 MiB")

        let (cancelled, cancelLog) = try service("slow")
        let running = Task { try await cancelled.transcribe(wav: wave, context: [], cleanup: true) }
        try await until { events(cancelLog).contains { $0["event"] as? String == "request" } }
        let pid = events(cancelLog).first { $0["event"] as? String == "launch" }!["pid"] as! Int32
        cancelled.cancelCurrentRequest()
        do { _ = try await running.value; preconditionFailure("Cancellation must not return a successful inference") } catch is CancellationError {}
        try await until { kill(pid, 0) != 0 }
        let retry = try await cancelled.clean(text: "再试一次", context: [])
        precondition(!retry.isEmpty && events(cancelLog).filter { $0["event"] as? String == "launch" }.count == 2)
        cancelled.cancelCurrentRequest()
        let (warmRace, warmRaceLog) = try service()
        let obsoleteWarm = Task { try await warmRace.warmUp() }
        try await until { !events(warmRaceLog).isEmpty }
        obsoleteWarm.cancel() // queues its onCancel main-actor handler
        warmRace.cancelCurrentRequest() // releases the old token immediately
        // This direct await starts a replacement process before the queued old handler runs.
        try await warmRace.warmUp()
        do { try await obsoleteWarm.value; preconditionFailure("Old warming task must be cancelled") } catch is CancellationError {}
        precondition(events(warmRaceLog).filter { $0["event"] as? String == "launch" }.count == 2)
        _ = try await warmRace.clean(text: "新加载不能被旧取消杀掉", context: [])
        warmRace.cancelCurrentRequest()

        let (requestRace, requestRaceLog) = try service()
        let obsoleteRequest = Task { try await requestRace.transcribe(wav: wave, context: [], cleanup: true) }
        try await until { events(requestRaceLog).contains { $0["event"] as? String == "request" } }
        obsoleteRequest.cancel() // its request-id/generation handler is deliberately late
        requestRace.cancelCurrentRequest()
        let freshText = try await requestRace.clean(text: "立即重试的新请求", context: [])
        do { _ = try await obsoleteRequest.value; preconditionFailure("Old inference must be cancelled") } catch is CancellationError {}
        precondition(freshText == "这是整理后的文字。")
        requestRace.cancelCurrentRequest()
        print("PASS actual Process cancellation, immediate warm/request restart before late onCancel, token/generation isolation, and retry")

        for mode in ["crash", "invalid", "error"] {
            let (broken, _) = try service(mode)
            do { _ = try await broken.transcribe(wav: wave, context: [], cleanup: true); preconditionFailure("Expected \(mode) to fail") }
            catch { precondition(!(error is CancellationError)) }
            broken.cancelCurrentRequest()
        }
        let (timeout, _) = try service("slow", request: 0.15)
        do { _ = try await timeout.transcribe(wav: wave, context: [], cleanup: true); preconditionFailure("Expected timeout") } catch { precondition(error.localizedDescription.contains("超时")) }
        let (cold, _) = try service("slow_start", startup: 0.15)
        do { try await cold.warmUp(); preconditionFailure("Expected startup timeout") } catch { precondition(error.localizedDescription.contains("超时")) }
        let (idle, idleLog) = try service(idle: 0.1)
        try await idle.warmUp()
        let idlePID = events(idleLog).first { $0["event"] as? String == "launch" }!["pid"] as! Int32
        try await until { kill(idlePID, 0) != 0 }
        try await idle.warmUp(); precondition(events(idleLog).filter { $0["event"] as? String == "launch" }.count == 2); idle.cancelCurrentRequest()
        let (warmCancelled, warmLog) = try service("slow_start")
        let warming = Task { try await warmCancelled.warmUp() }
        try await until { !events(warmLog).isEmpty }
        let warmPID = events(warmLog).first!["pid"] as! Int32
        warmCancelled.cancelCurrentRequest()
        do { try await warming.value; preconditionFailure("Cancelled warm-up must end") } catch is CancellationError {}
        try await until { kill(warmPID, 0) != 0 }
        let (blocked, blockedLog) = try service("no_read")
        try await blocked.warmUp()
        let largeWave = LocalAIMemoryAudioCollector.wav(Data(repeating: 1, count: 120 * 32_000))
        let blockedWrite = Task { try await blocked.transcribe(wav: largeWave, context: [], cleanup: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let blockedPID = events(blockedLog).first!["pid"] as! Int32
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        blocked.cancelCurrentRequest()
        precondition(ProcessInfo.processInfo.systemUptime - cancelledAt < 0.2, "Cancelling a blocked pipe write must not block the main actor")
        do { _ = try await blockedWrite.value; preconditionFailure("Blocked write must be cancelled") } catch is CancellationError {}
        try await until { kill(blockedPID, 0) != 0 }
        print("PASS startup/request deadlines, protocol errors, inference errors, idle exit, warm cancellation, and nonblocking large-write cancellation")

        let (partial, _) = try service("cleanup_failure")
        let partialCapture = LocalAISpeechCapture(service: partial, cloudCleanupEnabled: { false })
        try partialCapture.beginBufferedCaptureForTesting(format: pcm().format); partialCapture.appendPCMForTesting(pcm())
        let raw = await partialCapture.stop()
        precondition(raw == partialCapture.originalTranscript && !partialCapture.cleanupApplied && partialCapture.cleanupIssue != nil && partialCapture.hasFinalResult)
        do { _ = try await partial.clean(text: "不能掩盖整理失败", context: []); preconditionFailure("Manual cleanup must surface the helper cleanup issue") }
        catch { precondition(error.localizedDescription.contains("模拟整理失败")) }
        partial.cancelCurrentRequest(); client.cancelCurrentRequest()
        for (mode, expectedKind) in [("cleanup_retained", LocalAICleanupIssueKind.retainedOriginal),
                                     ("cleanup_generated", LocalAICleanupIssueKind.generationFailed)] {
            let (typed, _) = try service(mode)
            let response = try await typed.transcribe(wav: wave, context: [], cleanup: true)
            precondition(response.text == response.originalText && !response.cleanupApplied && response.cleanupIssueKind == expectedKind)
            do {
                _ = try await typed.clean(text: "整理结果状态检查", context: [])
                preconditionFailure("Cleanup with an issue must not silently succeed")
            } catch let error as SpeechTextCleanupError {
                guard expectedKind == .retainedOriginal, case .rejected = error else { throw error }
            } catch {
                precondition(expectedKind == .generationFailed && error.localizedDescription.contains("模拟整理失败"))
            }
            typed.cancelCurrentRequest()
        }
        for mode in ["cleanup_failure", "cleanup_unknown"] {
            let (legacy, _) = try service(mode)
            do {
                _ = try await legacy.clean(text: "旧版与未知状态检查", context: [])
                preconditionFailure("Missing/unknown cleanup kind must remain a failure")
            } catch {
                precondition(!(error is SpeechTextCleanupError), "Do not infer a retained-original warning from localized message text")
                precondition(error.localizedDescription.contains("模拟整理失败"))
            }
            legacy.cancelCurrentRequest()
        }
        print("PASS typed retained-original vs generation failure feedback; legacy/unknown worker kinds remain failures")
        let availability = await Task.detached { LocalAIVoiceService.runtimeAvailability }.value
        if !availability.isReady {
            let hybrid = SpeechInputFactory.make(); hybrid.configure(options: SpeechRecognitionOptions(mode: .localAI))
            do { try await hybrid.start(); preconditionFailure("Unprepared local AI must not silently use an Apple recognizer") }
            catch { precondition(error.localizedDescription.contains("本地 AI 尚未准备")) }
        }
        print("PASS cleanup failure preserves ASR original; runtime availability is nonisolated and read-only (ready=\(availability.isReady))")

        let cloudGate = CloudCleanupProbe()
        var cloudEnabled = true
        let (cloudClient, cloudLog) = try service()
        let cloudCapture = LocalAISpeechCapture(service: cloudClient, cloudCleanupEnabled: { cloudEnabled },
            cloudCleaner: { await cloudGate.run($0, $1) })
        cloudCapture.configure(options: .init(mode: .localAI, contextualStrings: ["熊本"]))
        try cloudCapture.beginBufferedCaptureForTesting(format: pcm().format); cloudCapture.appendPCMForTesting(pcm())
        let cloudStop = Task { await cloudCapture.stop() }
        for _ in 0..<100 { if await cloudGate.requests.count > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let submitted = await cloudGate.requests
        precondition(submitted.count == 1 && submitted[0].0 == result.originalText && submitted[0].1 == ["熊本"])
        precondition(cloudCapture.transcript == result.originalText && cloudCapture.hasFinalResult && cloudCapture.status.contains("DeepSeek"))
        precondition(events(cloudLog).last?["cleanup"] as? Bool == false, "Cloud path must skip the local text rewrite")
        cloudEnabled = false // Already started utterance keeps its explicit snapshot.
        await cloudGate.finish("今天去了海边，很开心。")
        let cloudText = await cloudStop.value
        precondition(cloudText == result.text && cloudCapture.originalTranscript == result.originalText && cloudCapture.cleanupApplied)

        let failedCloud = LocalAISpeechCapture(service: cloudClient, cloudCleanupEnabled: { true }, cloudCleaner: { _, _ in throw DeepSeekTextError.network })
        try failedCloud.beginBufferedCaptureForTesting(format: pcm().format); failedCloud.appendPCMForTesting(pcm())
        let failedCloudText = await failedCloud.stop()
        precondition(failedCloudText == result.originalText && failedCloud.cleanupIssue?.contains("DeepSeek") == true && !failedCloud.cleanupApplied && failedCloud.hasFinalResult)

        cloudEnabled = true
        try cloudCapture.beginBufferedCaptureForTesting(format: pcm().format); cloudCapture.appendPCMForTesting(pcm())
        let abandonedCloud = Task { await cloudCapture.stop() }
        for _ in 0..<100 { if await cloudGate.requests.count > 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        cloudCapture.cancel(); cloudEnabled = false
        try cloudCapture.beginBufferedCaptureForTesting(format: pcm().format); cloudCapture.appendPCMForTesting(pcm())
        let newLocalText = await cloudCapture.stop()
        await cloudGate.finish("迟到的云端结果不可覆盖新口述")
        let abandonedCloudText = await abandonedCloud.value
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(abandonedCloudText.isEmpty && newLocalText == result.text && cloudCapture.transcript == result.text && cloudCapture.cleanupIssue == nil)
        cloudClient.cancelCurrentRequest()
        print("PASS local-ASR → cloud text-only snapshot, one rewrite, raw/final retention, network failure fallback, cancellation and late-result isolation (injected cleaner, no network)")

        if ProcessInfo.processInfo.environment["YINGSHU_LOCAL_AI_REAL"] == "1" {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("YingShu/AI Runtime/manifest.json")
            let workerURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YINGSHU_LOCAL_AI_WORKER"]!)
            let actual = LocalAIVoiceService(manifestURL: support, workerURL: workerURL, startupTimeout: 90, requestTimeout: 180)
            guard actual.isReady else { print("SKIP real model: \(actual.availabilityMessage)"); return }
            let actualCapture = LocalAISpeechCapture(service: actual, cloudCleanupEnabled: { false })
            let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YINGSHU_LOCAL_AI_FIXTURE"]!)
            let text = try await actualCapture.transcribeFile(url: fixture)
            print("REAL_LOCAL_AI original=\(actualCapture.originalTranscript ?? "") final=\(text) cleanupApplied=\(actualCapture.cleanupApplied) cleanupIssue=\(actualCapture.cleanupIssue ?? "none")")
            precondition(!text.isEmpty && actualCapture.originalTranscript?.isEmpty == false && actualCapture.hasFinalResult && actualCapture.wordSegments.isEmpty)
            actual.cancelCurrentRequest()
            print("PASS actual local ASR + LLM helper against generated Mandarin file, without microphone or API key")
        }
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SpeechRecognitionFailure.message("测试等待超时。") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static let fakeWorker = #"""
import argparse, base64, json, os, signal, sys, time
p=argparse.ArgumentParser(); p.add_argument('--manifest'); a=p.parse_args()
m=json.load(open(a.manifest)); mode=m['test_mode']
def log(**event):
    with open(m['test_log'],'a') as f: f.write(json.dumps(event)+'\n')
def reply(value):
    line=json.dumps(value,ensure_ascii=False)+'\n'
    split=len(line)//2
    sys.stdout.write(line[:split]); sys.stdout.flush(); time.sleep(.002)
    sys.stdout.write(line[split:]); sys.stdout.flush()
log(event='launch',pid=os.getpid())
if mode=='slow_start': time.sleep(10)
else: time.sleep(.05)
reply({'status':'ready'})
if mode=='no_read': time.sleep(10)
for line in sys.stdin:
    request=json.loads(line); action=request['action']; id=request['id']
    log(event='request',action=action,id=id,cleanup=request.get('cleanup'))
    if mode=='crash': os._exit(9)
    if mode=='invalid': print('bad json',flush=True); continue
    if mode=='error': reply({'id':id,'ok':False,'error':'模拟识别失败'}); continue
    if mode=='slow' and action=='transcribe': time.sleep(10)
    reply({'id':'stale-id','ok':True,'text':'旧回调不能覆盖'})
    time.sleep(.03)
    failed_cleanup=mode in ('cleanup_failure','cleanup_retained','cleanup_generated','cleanup_unknown')
    cleanup_kind={'cleanup_retained':'retained_original','cleanup_generated':'generation_failed','cleanup_unknown':'future_kind'}.get(mode)
    if action=='transcribe':
        wav=base64.b64decode(request['audio_base64']); assert wav[:4]==b'RIFF' and wav[8:12]==b'WAVE'
        assert len(wav)<=4*1024*1024
        original='今天呃去了海边海边，很开心'
        reply({'id':id,'ok':True,'text':original if failed_cleanup or not request.get('cleanup',True) else '今天去了海边，很开心。','original_text':original,
            'cleanup_applied':not failed_cleanup and request.get('cleanup',True),'cleanup_issue':'模拟整理失败，保留原稿' if failed_cleanup else None,'cleanup_issue_kind':cleanup_kind,
            'metrics':{'asr_seconds':.12,'cleanup_seconds':.08}})
    else: reply({'id':id,'ok':True,'text':request['text'] if failed_cleanup else '这是整理后的文字。','original_text':request['text'],
        'cleanup_applied':not failed_cleanup,'cleanup_issue':'模拟整理失败，保留原稿' if failed_cleanup else None,'cleanup_issue_kind':cleanup_kind})
"""#
}
