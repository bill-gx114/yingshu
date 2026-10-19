import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation

/// This protocol intercepts every request made by the injected ephemeral session.
/// All bytes come from a generated silent MP3; no external server is contacted.
private final class StateStreamProtocol: URLProtocol {
    static let fixtures = StateStreamFixtures()
    private let delivery = DispatchQueue(label: "yingshu.test.model-silent-stream")
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.fixtures.begin(request)
        delivery.async { [self] in
            guard !stopped, let url = request.url else { return }
            let headers = ["Content-Type": "audio/mpeg", "Content-Length": String(reply.body.count),
                           "Content-Range": "bytes 0-\(reply.body.count - 1)/\(reply.total)"]
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            send(reply, offset: 0)
        }
    }
    private func send(_ reply: StateStreamFixtures.Reply, offset: Int) {
        delivery.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !stopped else { return }
            let end = min(offset + 64 * 1024, reply.body.count)
            guard end > offset else { return }
            let data = reply.body.subdata(in: offset..<end)
            Self.fixtures.delivered(data.count, path: request.url!.path)
            client?.urlProtocol(self, didLoad: data)
            if end == reply.body.count {
                Self.fixtures.finished(path: request.url!.path)
                client?.urlProtocolDidFinishLoading(self)
            } else { send(reply, offset: end) }
        }
    }
    override func stopLoading() {
        // The same serial queue orders cancellation before any subsequent chunk.
        delivery.async { [self] in
            guard !stopped else { return }
            stopped = true
            Self.fixtures.stopped(path: request.url!.path)
        }
    }
}

private final class StateStreamFixtures: @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var total: Int }
    struct Snapshot { var requests: [URLRequest] = []; var bytes = 0; var stops = 0; var finishes = 0 }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var history: [String: Snapshot] = [:]
    func install(path: String, body: Data, total: Int, status: Int = 206) {
        lock.lock(); defer { lock.unlock() }
        replies[path] = Reply(status: status, body: body, total: total)
    }
    func begin(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        history[path, default: Snapshot()].requests.append(request)
        return replies[path] ?? Reply(status: 404, body: Data(), total: 0)
    }
    func delivered(_ bytes: Int, path: String) { lock.lock(); history[path, default: Snapshot()].bytes += bytes; lock.unlock() }
    func stopped(path: String) { lock.lock(); history[path, default: Snapshot()].stops += 1; lock.unlock() }
    func finished(path: String) { lock.lock(); history[path, default: Snapshot()].finishes += 1; lock.unlock() }
    func snapshot(path: String) -> Snapshot { lock.lock(); defer { lock.unlock() }; return history[path] ?? Snapshot() }
}

@MainActor private final class StreamStateSpeech: SpeechInput {
    private let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var status = "静音流式测试"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    func start() async throws { isRecording = true; updates.send() }
    func stop() async -> String { isRecording = false; updates.send(); return "" }
    func cancel() { isRecording = false; updates.send() }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String {
        throw CheckFailure.message("The streaming state test must never invoke a speech service")
    }
}

@MainActor private final class StreamSessionRecorder {
    var sessions: [OnlineMusicPreviewSession] = []
    func make(_ track: OnlineMusicTrack, configuration: URLSessionConfiguration) throws -> OnlineMusicPreviewSession {
        let session = try OnlineMusicPreviewSession(track: track, configuration: configuration, useMemoryCache: false)
        sessions.append(session)
        return session
    }
}

@main @MainActor enum StreamingPreviewStateChecks {
    private static var checkCount = 0
    static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            fputs("FAIL: streaming AppModel checks exceeded their 45-second runtime limit.\n", stderr)
            Darwin.exit(124)
        }
        guard let fixture = ProcessInfo.processInfo.environment["YINGSHU_STREAM_STATE_FIXTURE"] else {
            throw CheckFailure.message("Missing generated silent MP3 fixture")
        }
        let whole = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let prefix = Data(whole.prefix(OnlineMusicPreview.maximumNetworkBytes))
        try check(prefix.count == 2 * 1024 * 1024 && whole.count > prefix.count, "Fixture is a genuine 2 MiB prefix of a longer silent MP3")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateStreamProtocol.self]
        configuration.urlCache = nil
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YingShuStreamingState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let speech = StreamStateSpeech(), recorder = StreamSessionRecorder()
        // Deliberately omit musicPreviewPreparer: this exercises the production stream branch.
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, speechInput: speech,
            musicPreviewStreamFactory: { try recorder.make($0, configuration: configuration) })
        do {
            let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/demo-coast.png")
            var clip = try await MediaEngine.inspect(url: source)
            clip.duration = 8
            model.clips = [clip]; model.automaticEditEnabled = false; model.musicVolume = 0
            model.captions = [Caption(clipID: clip.id, start: 0, duration: 8, text: "独立流式状态检查", style: .sticker)]
            model.seek(to: 1.25)
            let original = try documentObject(model)
            let project = root.appendingPathComponent("own-fixture-project.json")
            try JSONEncoder().encode(model.document).write(to: project)
            let fixtures = StateStreamProtocol.fixtures

            let early = track("early")
            fixtures.install(path: early.audioURL.path, body: prefix, total: whole.count)
            let started = ProcessInfo.processInfo.systemUptime
            model.toggleOnlineMusicPreview(early)
            try check(model.remotePreviewTrackID == early.id && model.isLoadingRemoteMusicPreview,
                      "The real stream branch publishes its track and loading state synchronously")
            let firstSession = recorder.sessions.last!
            let samples = try await waitForRealPlayback(model, track: early, timeout: 5)
            let metrics = model.currentPreviewStreamMetrics!
            let clock = model.currentPreviewPlaybackTime!
            try check(!metrics.networkFinished && metrics.receivedBytes > 0 && metrics.receivedBytes < prefix.count,
                      "AppModel clears loading while the slow HTTP response is still incomplete")
            try check(firstSession.item.status == .readyToPlay && clock > 0.03 && samples > 0,
                      "Loading is gated by an advancing playback clock, with observations before that clock, not item readiness alone")
            try check(!metrics.fromMemoryCache && fixtures.snapshot(path: early.audioURL.path).requests.count == 1,
                      "The assertion uses a new actual URLProtocol transfer rather than cached audio")
            let request = fixtures.snapshot(path: early.audioURL.path).requests[0]
            try check(request.value(forHTTPHeaderField: "Range") == "bytes=0-2097151" && request.value(forHTTPHeaderField: "Referer") == early.sourceURL.absoluteString,
                      "AppModel's streaming request keeps the bounded Range and source Referer")
            print(String(format: "STREAM_MODEL firstPlaying=%.3fs clock=%.3fs bytes=%d/%d networkFinished=%@ preClockSamples=%d",
                         ProcessInfo.processInfo.systemUptime - started, clock, metrics.receivedBytes, prefix.count,
                         String(metrics.networkFinished), samples))
            model.stopOnlineMusicPreview()
            try await assertCancelled(firstSession, path: early.audioURL.path)
            try check(model.remotePreviewTrackID == nil && !model.isLoadingRemoteMusicPreview && model.currentPreviewStreamMetrics == nil,
                      "Stopping clears the model's live stream state")
            try check(try documentObject(model) == original, "Listening and stopping leave the project document unchanged")
            print("PASS production AppModel stream starts on a real muted playback clock before HTTP completion; stop cancels the actual request")

            let movie = track("movie")
            fixtures.install(path: movie.audioURL.path, body: prefix, total: whole.count)
            model.toggleOnlineMusicPreview(movie)
            let movieSession = recorder.sessions.last!
            try await waitUntil("movie-interruption request begins") { movieSession.metrics.receivedBytes > 0 }
            model.play()
            try check(model.isPlaying && model.remotePreviewTrackID == nil, "Movie playback interrupts the real in-progress stream")
            try await assertCancelled(movieSession, path: movie.audioURL.path)
            model.pause()

            let dictation = track("dictation")
            fixtures.install(path: dictation.audioURL.path, body: prefix, total: whole.count)
            model.toggleOnlineMusicPreview(dictation)
            let dictationSession = recorder.sessions.last!
            try await waitUntil("dictation-interruption request begins") { dictationSession.metrics.receivedBytes > 0 }
            model.toggleRecording()
            try await waitUntil("fake dictation starts without a microphone") { speech.isRecording }
            try check(model.remotePreviewTrackID == nil && !model.isLoadingRemoteMusicPreview,
                      "Dictation interrupts the production stream without using a microphone")
            try await assertCancelled(dictationSession, path: dictation.audioURL.path)
            await model.finishRecording(autoResume: false)
            try check(try documentObject(model) == original, "Movie and empty fake dictation do not change the document")
            print("PASS movie playback and injected dictation each cancel an actual progressive request")

            let retry = track("retry")
            fixtures.install(path: retry.audioURL.path, body: prefix, total: whole.count, status: 429)
            model.toggleOnlineMusicPreview(retry)
            let failedSession = recorder.sessions.last!
            try await waitUntil("429 becomes an inline message") { model.remotePreviewTrackID == nil }
            try check(model.remoteMusicPreviewMessage == OnlineMusicPreviewError.rateLimited.localizedDescription && model.errorMessage == nil,
                      "HTTP 429 preserves the stream's real inline rate-limit message without a modal error")
            try check(failedSession.metrics.failureMessage == OnlineMusicPreviewError.rateLimited.localizedDescription,
                      "The inline message comes from the real streaming failure")
            try await assertCancelled(failedSession, path: retry.audioURL.path)
            try check(fixtures.snapshot(path: retry.audioURL.path).bytes == 0, "A 429 response is cancelled before any audio body is delivered")
            fixtures.install(path: retry.audioURL.path, body: prefix, total: whole.count)
            model.toggleOnlineMusicPreview(retry)
            let retrySession = recorder.sessions.last!
            _ = try await waitForRealPlayback(model, track: retry, timeout: 5)
            try check(fixtures.snapshot(path: retry.audioURL.path).requests.count == 2 && model.remoteMusicPreviewMessage.contains(retry.name),
                      "The same failed track can retry through a new request and reach real playback")
            model.stopOnlineMusicPreview()
            try await assertCancelled(retrySession, path: retry.audioURL.path, minimumStops: 2)
            print("PASS real 429 stays inline; the same track retries successfully through the production stream factory")

            let replaced = track("project")
            fixtures.install(path: replaced.audioURL.path, body: prefix, total: whole.count)
            model.toggleOnlineMusicPreview(replaced)
            let projectSession = recorder.sessions.last!
            try await waitUntil("project-interruption request begins") { projectSession.metrics.receivedBytes > 0 }
            try model.applyDocument(from: project)
            try await assertCancelled(projectSession, path: replaced.audioURL.path)
            try check(model.remotePreviewTrackID == nil && !model.isLoadingRemoteMusicPreview,
                      "Opening the test-owned project clears the old actual stream")
            try check(try documentObject(model) == original && model.downloadedMusic.isEmpty && model.musicID == "breeze",
                      "Streaming, errors, retry and project replacement leave music selection and document unchanged")
            await model.prepareToTerminate()
            print("PASS project replacement cancels the real stream; no downloaded track, autosave, real network, microphone or user project was used")
            print("PASS StreamingPreviewStateChecks: \(checkCount) assertions on the production streamFactory branch (not the legacy preparer gate)")
        } catch {
            await model.prepareToTerminate()
            throw error
        }
    }

    private static func track(_ id: String) -> OnlineMusicTrack {
        OnlineMusicTrack(id: "stream-state-" + id, name: "静音流式测试 " + id, artist: "Generated silence",
            audioURL: URL(string: "https://streaming-state.invalid/\(id).mp3")!,
            sourceURL: URL(string: "https://streaming-state.invalid/source/\(id)")!, license: "CC0 1.0",
            licenseURL: URL(string: "https://streaming-state.invalid/license")!, duration: 70)
    }
    private static func documentObject(_ model: AppModel) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.document)) as! NSDictionary
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { throw CheckFailure.message(description) }
        checkCount += 1
    }
    private static func waitUntil(_ description: String, timeout: Double = 3, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure.message("Timed out: " + description)
    }
    private static func waitForRealPlayback(_ model: AppModel, track: OnlineMusicTrack, timeout: Double) async throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var preClockSamples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard model.remotePreviewTrackID == track.id else {
                throw CheckFailure.message("Stream stopped before real playback: " + model.remoteMusicPreviewMessage)
            }
            let clock = model.currentPreviewPlaybackTime ?? 0
            if clock <= 0.03 {
                try check(model.isLoadingRemoteMusicPreview, "Loading must remain true until real playback time exceeds 0.03 seconds")
                preClockSamples += 1
            }
            if !model.isLoadingRemoteMusicPreview {
                try check(clock > 0.03, "A loading=false state must be accompanied by a real advancing playback clock")
                try check(model.currentPreviewStreamMetrics?.networkFinished == false, "Playback becomes active before the slow network response finishes")
                return preClockSamples
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure.message("No active AppModel playback within \(timeout)s; clock=\(model.currentPreviewPlaybackTime ?? -1), metrics=\(String(describing: model.currentPreviewStreamMetrics)), message=\(model.remoteMusicPreviewMessage)")
    }
    private static func assertCancelled(_ session: OnlineMusicPreviewSession, path: String, minimumStops: Int = 1) async throws {
        let fixtures = StateStreamProtocol.fixtures
        try await waitUntil("the underlying URLProtocol request receives stopLoading") {
            session.metrics.isCancelled && fixtures.snapshot(path: path).stops >= minimumStops
        }
        let received = session.metrics.receivedBytes
        let delivered = fixtures.snapshot(path: path).bytes
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(session.metrics.receivedBytes == received && fixtures.snapshot(path: path).bytes == delivered,
                  "Cancelled \(path) receives no further fixture or streaming-loader bytes")
    }
}

private enum CheckFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return "StreamingPreviewStateChecks: " + value }; return nil }
}
