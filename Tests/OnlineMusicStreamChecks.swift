import AppKit
import AVFoundation
import Foundation

private final class StreamProtocol: URLProtocol {
    static let state = StreamFixtures()
    private let lock = NSLock()
    private var stopped = false
    private let delivery = DispatchQueue(label: "yingshu.test.slow-mp3")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.reply(for: request)
        guard let url = request.url else { return }
        if let redirect = reply.redirect, url.path.hasSuffix("stream.mp3") {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(reply, at: 0)
    }
    private func send(_ reply: StreamFixtures.Reply, at offset: Int) {
        delivery.asyncAfter(deadline: .now() + reply.chunkDelay) { [self] in
            lock.lock(); let active = !stopped; lock.unlock()
            guard active else { return }
            guard offset < reply.body.count else { client?.urlProtocolDidFinishLoading(self); return }
            let end = min(offset + reply.chunkSize, reply.body.count)
            let data = reply.body.subdata(in: offset..<end)
            Self.state.delivered(data.count)
            client?.urlProtocol(self, didLoad: data)
            if end == reply.body.count { client?.urlProtocolDidFinishLoading(self) }
            else { send(reply, at: end) }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock(); Self.state.stopped() }
}

private final class StreamFixtures: @unchecked Sendable {
    struct Reply {
        var status = 206
        var headers: [String: String]
        var body: Data
        var chunkSize = 32 * 1024
        var chunkDelay: Double = 0.1
        var redirect: URL?
    }
    private let lock = NSLock()
    private var current = Reply(headers: [:], body: Data())
    private var requests: [URLRequest] = []
    private var bytes = 0, stops = 0
    func reset(_ body: Data, total: Int, delay: Double = 0.1, chunk: Int = 32 * 1024) {
        lock.lock(); defer { lock.unlock() }
        current = Reply(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(body.count), "ETag": "\"fixture-v1\"",
                                 "Content-Range": "bytes 0-\(body.count - 1)/\(total)"], body: body, chunkSize: chunk, chunkDelay: delay)
        requests = []; bytes = 0; stops = 0
    }
    func change(_ action: (inout Reply) -> Void) { lock.lock(); action(&current); lock.unlock() }
    func reply(for request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        var reply = current
        if let value = request.value(forHTTPHeaderField: "Range"), value.hasPrefix("bytes="),
           let first = value.dropFirst(6).split(separator: "-").first, let start = Int(first), start > 0, start < reply.body.count {
            let end = reply.body.count - 1
            reply.body = reply.body.subdata(in: start..<(end + 1))
            reply.headers["Content-Length"] = String(reply.body.count)
            reply.headers["Content-Range"] = "bytes \(start)-\(end)/9999999"
        }
        return reply
    }
    func delivered(_ count: Int) { lock.lock(); bytes += count; lock.unlock() }
    func stopped() { lock.lock(); stops += 1; lock.unlock() }
    func snapshot() -> (requests: [URLRequest], bytes: Int, stops: Int) { lock.lock(); defer { lock.unlock() }; return (requests, bytes, stops) }
}

@main enum OnlineMusicStreamChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let fixture = ProcessInfo.processInfo.environment["YINGSHU_PREVIEW_FIXTURE"]!
        let whole = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let prefix = Data(whole.prefix(OnlineMusicPreview.maximumNetworkBytes))
        precondition(prefix.count < whole.count)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamProtocol.self]
        let track = OnlineMusicTrack(id: "stream-\(UUID().uuidString)", name: "Generated progressive MP3", artist: "Test oscillator",
                                     audioURL: URL(string: "https://ccmixter.org/content/stream.mp3")!,
                                     sourceURL: URL(string: "https://ccmixter.org/files/fixture/1")!, license: "CC0 1.0",
                                     licenseURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!, duration: 60)
        let source = StreamProtocol.state
        source.reset(prefix, total: whole.count)
        let started = ProcessInfo.processInfo.systemUptime
        let session = try OnlineMusicPreviewSession(track: track, configuration: config, useMemoryCache: false)
        let player = mutedPlayer(session.item)
        try await waitUntil(seconds: 12, description: "first moving playback clock", session: session, player: player) { player.currentTime().seconds >= 0.25 }
        let firstClock = ProcessInfo.processInfo.systemUptime - started
        let first = session.metrics
        precondition(player.timeControlStatus == .playing && session.item.status == .readyToPlay,
                     "A ready item without active playback does not prove low startup latency")
        precondition(!first.networkFinished && first.receivedBytes < prefix.count / 2,
                     "A moving player clock must precede most of the response: first=\(firstClock)s bytes=\(first.receivedBytes) complete=\(first.networkFinished)")
        try await waitUntil(seconds: 5, description: "one second of actual playback", session: session, player: player) { player.currentTime().seconds >= 1 }
        precondition(!session.metrics.networkFinished && session.metrics.receivedBytes < prefix.count / 2)
        print(String(format: "PROGRESSIVE firstClock=%.3fs firstByte=%.3fs bytesAtFirstClock=%d/%d clockNow=%.3fs", firstClock, first.firstByteDelay ?? -1, first.receivedBytes, prefix.count, player.currentTime().seconds))
        player.pause(); player.replaceCurrentItem(with: nil); session.cancel()
        let stoppedBytes = session.metrics.receivedBytes
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(session.metrics.isCancelled && session.metrics.receivedBytes == stoppedBytes && source.snapshot().stops > 0)
        print("PASS slow chunked stream advances AVPlayer's muted playback clock while most of its HTTP response is pending; cancellation stops it")

        source.reset(prefix, total: whole.count)
        var partialTrack = track; partialTrack.id += "-partial"
        let partial = try OnlineMusicPreviewSession(track: partialTrack, configuration: config)
        let partialPlayer = mutedPlayer(partial.item)
        try await waitUntil(seconds: 8, description: "partially buffered valid audio", session: partial, player: partialPlayer) { partialPlayer.currentTime().seconds >= 0.25 }
        partialPlayer.pause(); partialPlayer.replaceCurrentItem(with: nil); partial.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        let partialBytes = partial.metrics.receivedBytes
        let resumed = try OnlineMusicPreviewSession(track: partialTrack, configuration: config)
        precondition(resumed.metrics.cacheHit && !resumed.metrics.networkFinished)
        let resumedPlayer = mutedPlayer(resumed.item)
        try await waitUntil(seconds: 5, description: "partially cached replay", session: resumed, player: resumedPlayer) { resumedPlayer.currentTime().seconds >= 0.25 }
        try await waitUntil(seconds: 5, description: "bounded continuation of partial cache", session: resumed, player: resumedPlayer) { source.snapshot().requests.contains { $0.value(forHTTPHeaderField: "Range") == "bytes=\(partialBytes)-2097151" } }
        precondition(source.snapshot().requests.last?.value(forHTTPHeaderField: "If-Range") == "\"fixture-v1\"")
        resumedPlayer.pause(); resumedPlayer.replaceCurrentItem(with: nil); resumed.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        print("PASS cancelling keeps validated partial bytes; replay starts from memory and resumes only the missing byte range")

        source.change { $0.headers["ETag"] = "\"fixture-v2\"" }
        try await expectFailure(.sourceChanged, track: partialTrack, config: config, useMemoryCache: true)
        let freshAfterChange = try OnlineMusicPreviewSession(track: partialTrack, configuration: config)
        precondition(!freshAfterChange.metrics.cacheHit, "A changed remote validator must invalidate old partial bytes rather than merging versions")
        freshAfterChange.cancel()
        print("PASS conditional If-Range resume rejects resource-version changes and clears its partial cache")

        if let vbrPath = ProcessInfo.processInfo.environment["YINGSHU_VBR_FIXTURE"] {
            let vbrWhole = try Data(contentsOf: URL(fileURLWithPath: vbrPath))
            let vbrPrefix = Data(vbrWhole.prefix(OnlineMusicPreview.maximumNetworkBytes))
            precondition(vbrWhole.count > vbrPrefix.count)
            source.reset(vbrPrefix, total: vbrWhole.count)
            let vbr = try OnlineMusicPreviewSession(track: track, configuration: config, useMemoryCache: false)
            let vbrPlayer = mutedPlayer(vbr.item)
            try await waitUntil(seconds: 12, description: "VBR/Xing progressive playback", session: vbr, player: vbrPlayer) { vbrPlayer.currentTime().seconds >= 0.25 }
            precondition(!vbr.metrics.networkFinished && vbr.metrics.receivedBytes < vbrPrefix.count / 2,
                         "VBR/Xing metadata must not force a whole-prefix wait: \(vbr.metrics)")
            vbrPlayer.pause(); vbrPlayer.replaceCurrentItem(with: nil); vbr.cancel()
            print("PASS VBR MP3 with a full-file Xing header also plays before half its prefix arrives")
        }

        source.reset(prefix, total: whole.count, delay: 0.02, chunk: prefix.count)
        let caching = try OnlineMusicPreviewSession(track: track, configuration: config)
        let firstPlayer = mutedPlayer(caching.item)
        try await waitUntil(seconds: 5, description: "cacheable playable response complete", session: caching, player: firstPlayer) { caching.metrics.networkFinished && firstPlayer.currentTime().seconds >= 0.1 }
        firstPlayer.pause(); firstPlayer.replaceCurrentItem(with: nil); caching.cancel()
        let beforeReplay = source.snapshot().requests.count
        let replay = try OnlineMusicPreviewSession(track: track, configuration: config)
        precondition(replay.metrics.fromMemoryCache)
        let replayPlayer = mutedPlayer(replay.item)
        try await waitUntil(seconds: 5, description: "cached replay moving clock", session: replay, player: replayPlayer) { replayPlayer.currentTime().seconds >= 0.25 }
        precondition(source.snapshot().requests.count == beforeReplay && replay.metrics.receivedBytes == 0, "A cached replay must not make a network request")
        let seeked = await withCheckedContinuation { continuation in
            replayPlayer.seek(to: CMTime(seconds: 19.7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { continuation.resume(returning: $0) }
        }
        precondition(seeked)
        replayPlayer.playImmediately(atRate: 1)
        try await waitUntil(seconds: 4, description: "twenty-second automatic stop", session: replay, player: replayPlayer) { replay.metrics.isCancelled }
        precondition(replayPlayer.currentTime().seconds <= 20.1)
        replayPlayer.pause(); replayPlayer.replaceCurrentItem(with: nil); replay.cancel()
        print("PASS in-memory replay has no network activity and forward playback stops at twenty seconds")

        source.reset(prefix, total: whole.count, delay: 0.3)
        source.change { $0.status = 200 }
        try await expectFailure(.rangeUnavailable, track: track, config: config)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(source.snapshot().bytes == 0, "Ignore-Range source must be cancelled at headers")
        source.reset(prefix, total: whole.count, delay: 0.02)
        source.change { $0.headers["Content-Type"] = "text/html" }
        try await expectFailure(.unsupportedFormat, track: track, config: config)
        source.reset(prefix, total: whole.count, delay: 0.02)
        source.change { $0.headers["Content-Range"] = "bytes 0-2097152/6000000"; $0.headers["Content-Length"] = nil }
        try await expectFailure(.tooLarge, track: track, config: config)
        source.reset(prefix, total: whole.count, delay: 0.02, chunk: prefix.count + 1)
        source.change { $0.body.append(0xff); $0.headers["Content-Length"] = nil }
        try await expectFailure(.tooLarge, track: track, config: config)
        source.reset(prefix, total: whole.count, delay: 0.02)
        source.change { $0.status = 429 }
        try await expectFailure(.rateLimited, track: track, config: config)
        source.reset(prefix, total: whole.count, delay: 0.8)
        try await expectFailure(.bufferTimeout, track: track, config: config, initialBufferTimeout: 0.2)
        source.reset(prefix, total: whole.count, delay: 0.02)
        source.change { $0.redirect = URL(string: "http://invalid.example/preview.mp3")! }
        try await expectFailure(.invalidURL, track: track, config: config)
        print("PASS ignored Range, HTML, oversized declaration/body, 429, and HTTPS downgrade terminate the progressive request")

        source.reset(prefix, total: whole.count, delay: 0.02, chunk: prefix.count)
        source.change { $0.redirect = URL(string: "https://audio.example.test/preview.mp3")! }
        let redirected = try OnlineMusicPreviewSession(track: track, configuration: config, useMemoryCache: false)
        let redirectedPlayer = mutedPlayer(redirected.item)
        try await waitUntil(seconds: 5, description: "redirected response", session: redirected, player: redirectedPlayer) { redirected.metrics.networkFinished }
        let actual = source.snapshot().requests.last!
        precondition(source.snapshot().requests.count == 2 && actual.value(forHTTPHeaderField: "Range") == "bytes=0-2097151"
                     && actual.value(forHTTPHeaderField: "Referer") == track.sourceURL.absoluteString)
        redirectedPlayer.pause(); redirectedPlayer.replaceCurrentItem(with: nil); redirected.cancel()
        print("PASS valid redirect preserves bounded Range/Referer, and a new stream still works after failures")
    }

    @MainActor private static func mutedPlayer(_ item: AVPlayerItem) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0; player.automaticallyWaitsToMinimizeStalling = false
        player.playImmediately(atRate: 1)
        return player
    }
    @MainActor private static func waitUntil(seconds: Double, description: String, session: OnlineMusicPreviewSession,
                                            player: AVPlayer, condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return }
            if let issue = session.metrics.failureMessage { preconditionFailure("\(description): \(issue)") }
            if session.item.status == .failed { preconditionFailure("\(description): AVPlayer failed \(String(describing: session.item.error)); metrics=\(session.metrics)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out: \(description); clock=\(player.currentTime().seconds); status=\(session.item.status.rawValue); metrics=\(session.metrics)")
    }
    @MainActor private static func expectFailure(_ expected: OnlineMusicPreviewError, track: OnlineMusicTrack, config: URLSessionConfiguration,
                                                initialBufferTimeout: TimeInterval = 15, useMemoryCache: Bool = false) async throws {
        let session = try OnlineMusicPreviewSession(track: track, configuration: config, useMemoryCache: useMemoryCache, initialBufferTimeout: initialBufferTimeout)
        let player = mutedPlayer(session.item)
        for _ in 0..<300 {
            if session.metrics.failureMessage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(session.metrics.failureMessage == expected.localizedDescription, "Expected \(expected): \(session.metrics)")
        player.pause(); player.replaceCurrentItem(with: nil); session.cancel()
    }
}
