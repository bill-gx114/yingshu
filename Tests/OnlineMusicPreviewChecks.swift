import AVFoundation
import Foundation

private final class PreviewProtocol: URLProtocol {
    static let state = PreviewFixtureState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.reply(for: request)
        guard let url = request.url else { return }
        if let redirect = reply.redirect, url.path.hasSuffix("fixture.mp3") {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: reply.responseURL ?? url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let active = !stopped; lock.unlock()
            guard active else { return }
            if !reply.body.isEmpty {
                Self.state.addDelivered(reply.body.count)
                client?.urlProtocol(self, didLoad: reply.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
        Self.state.addStop()
    }
}

private final class PreviewFixtureState: @unchecked Sendable {
    struct Reply {
        var status = 206
        var headers: [String: String] = [:]
        var body = Data()
        var delay: Double = 0.03
        var responseURL: URL?
        var redirect: URL?
    }
    private let lock = NSLock()
    private var current = Reply()
    private var requests: [URLRequest] = []
    private var delivered = 0, stops = 0
    func reset(body: Data, total: Int) {
        lock.lock(); defer { lock.unlock() }
        current = Reply(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(body.count),
                                 "Content-Range": "bytes 0-\(body.count - 1)/\(total)"], body: body)
        requests = []; delivered = 0; stops = 0
    }
    func change(_ action: (inout Reply) -> Void) { lock.lock(); defer { lock.unlock() }; action(&current) }
    func reply(for request: URLRequest) -> Reply { lock.lock(); defer { lock.unlock() }; requests.append(request); return current }
    func addDelivered(_ bytes: Int) { lock.lock(); delivered += bytes; lock.unlock() }
    func addStop() { lock.lock(); stops += 1; lock.unlock() }
    func snapshot() -> (requests: [URLRequest], delivered: Int, stops: Int) { lock.lock(); defer { lock.unlock() }; return (requests, delivered, stops) }
}

@main enum OnlineMusicPreviewChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        guard let fixturePath = ProcessInfo.processInfo.environment["YINGSHU_PREVIEW_FIXTURE"] else { preconditionFailure("Missing generated MP3 fixture") }
        let full = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let prefix = Data(full.prefix(OnlineMusicPreview.maximumNetworkBytes))
        precondition(full.count > prefix.count && prefix.count == 2 * 1024 * 1024, "Use an actual truncated MP3, not a whole-file fixture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-preview-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("preserve.txt"); try Data("unrelated".utf8).write(to: marker)
        let fixture = PreviewProtocol.state
        fixture.reset(body: prefix, total: full.count)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PreviewProtocol.self]
        let track = OnlineMusicTrack(id: "ccmixter-fixture", name: "Synthetic preview", artist: "Test oscillator",
                                     audioURL: URL(string: "https://ccmixter.org/content/fixture.mp3")!,
                                     sourceURL: URL(string: "https://ccmixter.org/files/fixture/1")!, license: "CC0 1.0",
                                     licenseURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!, duration: 60)
        let clip = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root)
        try await checkPlayable(clip)
        precondition(abs(clip.duration - 20) < 0.001)
        let outputFiles = try FileManager.default.contentsOfDirectory(atPath: clip.directory.path)
        precondition(outputFiles == ["preview.wav"], "Only the disposable playable clip remains; no raw prefix, metadata, license or project")
        let request = fixture.snapshot().requests.first!
        precondition(request.value(forHTTPHeaderField: "Range") == "bytes=0-2097151")
        precondition(request.value(forHTTPHeaderField: "Referer") == track.sourceURL.absoluteString)
        precondition(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        precondition(fixture.snapshot().delivered == 2 * 1024 * 1024)
        OnlineMusicPreview.remove(clip); OnlineMusicPreview.remove(clip)
        precondition(!FileManager.default.fileExists(atPath: clip.directory.path) && FileManager.default.fileExists(atPath: marker.path))
        print("PASS real truncated MP3 decode, exact twenty-second playable WAV, Range/referrer, temporary-only lifecycle")

        let short = Data(full.prefix(80_000))
        fixture.reset(body: short, total: full.count)
        let shortClip = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root)
        precondition(shortClip.duration >= 1 && shortClip.duration < 4)
        try await checkPlayable(shortClip)
        OnlineMusicPreview.remove(shortClip)
        print("PASS a shorter valid prefix yields its actual playable duration")

        fixture.reset(body: prefix, total: full.count)
        var insecure = track; insecure.audioURL = URL(string: "http://ccmixter.org/content/fixture.mp3")!
        await expect(.invalidURL) { _ = try await OnlineMusicPreview.prepare(track: insecure, configuration: config, temporaryRoot: root) }
        var unsupported = track; unsupported.audioURL = URL(string: "https://ccmixter.org/content/fixture.m4a")!
        await expect(.unsupportedFormat) { _ = try await OnlineMusicPreview.prepare(track: unsupported, configuration: config, temporaryRoot: root) }
        precondition(fixture.snapshot().requests.isEmpty, "Unsupported input must not start a transfer")

        fixture.change { $0.status = 200; $0.delay = 0.3; $0.headers["Content-Length"] = String(full.count) }
        await expect(.rangeUnavailable) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(fixture.snapshot().delivered == 0 && fixture.snapshot().stops > 0, "Ignoring Range must be stopped at headers instead of downloading a full song")
        try checkClean(root, marker: marker)
        print("PASS HTTPS/format checks, source ignoring Range rejected before its body, no full-song fallback")

        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.headers["Content-Range"] = nil }
        await expect(.invalidResponse) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.change { $0.headers["Content-Range"] = "bytes 1-2097151/6000000" }
        await expect(.tooLarge) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.change { $0.headers["Content-Range"] = "bytes 0-2097152/6000000" }
        await expect(.tooLarge) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.change { $0.headers["Content-Range"] = "bytes 0-2097151/10" }
        await expect(.invalidResponse) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.change { $0.headers["Content-Range"] = "bytes 0-2097151/6000000"; $0.headers["Content-Encoding"] = "gzip" }
        await expect(.invalidResponse) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.change { $0.headers["Content-Encoding"] = nil; $0.headers["Content-Type"] = "text/html" }
        await expect(.unsupportedFormat) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.reset(body: Data("<html>not audio</html>".utf8), total: 5000)
        await expect(.invalidAudio) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.status = 429 }
        await expect(.rateLimited) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        try checkClean(root, marker: marker)
        print("PASS invalid/malformed/oversized ranges, encoded bodies, HTML masquerade and clear 429 feedback")

        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.headers["Content-Length"] = nil; $0.body.append(0xff) }
        await expect(.tooLarge) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.headers["Content-Length"] = nil; $0.body = Data(prefix.prefix(8000)) }
        await expect(.invalidResponse) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        try checkClean(root, marker: marker)
        print("PASS dishonest/chunked oversize and prematurely ended responses never publish a clip")

        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.redirect = URL(string: "http://insecure.invalid/preview.mp3") }
        await expect(.invalidURL) { _ = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        precondition(fixture.snapshot().requests.count == 1, "Never follow an HTTPS downgrade")
        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.redirect = URL(string: "https://audio.example.test/preview.mp3") }
        let redirected = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root)
        precondition(fixture.snapshot().requests.count == 2)
        precondition(fixture.snapshot().requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-2097151")
        precondition(fixture.snapshot().requests.last?.value(forHTTPHeaderField: "Referer") == track.sourceURL.absoluteString)
        OnlineMusicPreview.remove(redirected)
        print("PASS HTTPS redirect validation and bounded Range/referrer retained across redirects")

        fixture.reset(body: prefix, total: full.count)
        fixture.change { $0.delay = 0.8 }
        let cancelled = Task { try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root) }
        for _ in 0..<200 {
            if !fixture.snapshot().requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Expected cancellation") }
        catch { precondition(error is CancellationError, "Expected CancellationError, received \(error)") }
        for _ in 0..<100 {
            if fixture.snapshot().stops > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(fixture.snapshot().stops > 0)
        try checkClean(root, marker: marker)
        fixture.reset(body: prefix, total: full.count)
        let next = try await OnlineMusicPreview.prepare(track: track, configuration: config, temporaryRoot: root)
        try await checkPlayable(next); OnlineMusicPreview.remove(next)
        try checkClean(root, marker: marker)
        print("PASS actual URLSession cancellation, directory cleanup, and a new preview after cancellation")

        if CommandLine.arguments.contains("--online") {
            let real = OnlineMusicTrack(id: "ccmixter-70150-126193", name: "ARK", artist: "zikweb",
                                        audioURL: URL(string: "https://ccmixter.org/content/zikweb/zikweb_-_ARK.mp3")!,
                                        sourceURL: URL(string: "https://ccmixter.org/files/zikweb/70150")!, license: "CC BY 2.5",
                                        licenseURL: URL(string: "https://creativecommons.org/licenses/by/2.5/")!, duration: 171)
            let live = try await OnlineMusicPreview.prepare(track: real)
            defer { OnlineMusicPreview.remove(live) }
            try await checkPlayable(live)
            precondition(abs(live.duration - 20) < 0.001)
            let contents = try FileManager.default.contentsOfDirectory(atPath: live.directory.path)
            precondition(contents == ["preview.wav"])
            print("ONLINE VERIFIED ARK: requested bytes 0-2097151, local playable duration=\(live.duration), temporary-only, no playback")
            OnlineMusicPreview.remove(live)
            precondition(!FileManager.default.fileExists(atPath: live.directory.path))
            print("PASS real ccMixter 206 prefix -> twenty-second native decode -> complete temporary cleanup")
        }
    }

    private static func expect(_ expected: OnlineMusicPreviewError, operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch { precondition((error as? OnlineMusicPreviewError) == expected, "Expected \(expected), received \(error)") }
    }
    private static func checkPlayable(_ clip: MusicPreviewClip) async throws {
        let asset = AVURLAsset(url: clip.url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        precondition(playable && duration >= 1 && duration <= 20.001 && abs(duration - clip.duration) < 0.001)
        let file = try AVAudioFile(forReading: clip.url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer)
        precondition(buffer.frameLength > 0)
    }
    private static func checkClean(_ root: URL, marker: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files == [marker.lastPathComponent], "Failed/cancelled previews must remove their complete temporary directories: \(files)")
    }
}
