import AVFoundation
import Foundation

private final class MusicProtocol: URLProtocol {
    struct Reply { var body: Data; var mime: String = "application/json"; var status = 200; var length: Int?; var delay: Double = 0 }
    static let state = Fixtures()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.state.reply(to: url)
        var headers = ["Content-Type": reply.mime]
        if let length = reply.length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let active = !stopped; lock.unlock()
            guard active else { return }
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private final class Fixtures: @unchecked Sendable {
    let lock = NSLock()
    var audio = Data()
    var searchRows: [[String: Any]] = []
    var detailRows: [[String: Any]] = []
    var openverseRows: [[String: Any]] = []
    var audioReply: MusicProtocol.Reply?
    var searchStatus = 200
    var openverseStatus = 200
    var requests: [URL] = []
    func reset(audio: Data, row: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        self.audio = audio; searchRows = [row]; detailRows = [row]; openverseRows = []
        audioReply = nil; searchStatus = 200; openverseStatus = 200; requests = []
    }
    func change(_ action: (Fixtures) -> Void) { lock.lock(); defer { lock.unlock() }; action(self) }
    func recorded() -> [URL] { lock.lock(); defer { lock.unlock() }; return requests }
    func reply(to url: URL) -> MusicProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(url)
        if url.host == "ccmixter.org", url.path == "/api/query" {
            let detail = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "ids" }) == true
            return MusicProtocol.Reply(body: try! JSONSerialization.data(withJSONObject: detail ? detailRows : searchRows), mime: "text/plain", status: searchStatus)
        }
        if url.host == "api.openverse.org" {
            let payload: Any
            if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1/audio" { payload = ["results": openverseRows] }
            else { payload = openverseRows.first ?? [:] }
            return MusicProtocol.Reply(body: try! JSONSerialization.data(withJSONObject: payload), status: openverseStatus)
        }
        return audioReply ?? MusicProtocol.Reply(body: audio, mime: "audio/wav", length: audio.count)
    }
}

@main enum OnlineMusicChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-music-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("fixture.wav")
        try makeWave(at: fixtureURL)
        let audio = try Data(contentsOf: fixtureURL)
        let row = ccRow(size: audio.count)
        let fixture = MusicProtocol.state
        fixture.reset(audio: audio, row: row)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MusicProtocol.self]

        let query = "fixture-\(UUID().uuidString)"
        let tracks = try await OnlineMusicLibrary.search(query: query, configuration: config, useCache: true)
        precondition(tracks.count == 1)
        let track = tracks[0]
        precondition(track.name == "海边测试曲" && track.artist == "Fixture Composer" && track.duration == 2 && track.license == "CC BY 3.0")
        precondition(track.licenseURL.absoluteString == "https://creativecommons.org/licenses/by/3.0/")
        let cached = try await OnlineMusicLibrary.search(query: query.uppercased(), configuration: config, useCache: true)
        precondition(cached == tracks && fixture.recorded().count == 2, "Same query reuses search and enriched-credit metadata")
        let searchItems = URLComponents(url: fixture.recorded()[0], resolvingAgainstBaseURL: false)!.queryItems!
        precondition(searchItems.contains { $0.name == "lic" && $0.value == "by,zero" })
        precondition(searchItems.contains { $0.name == "reqtags" && $0.value == "instrumental" })
        precondition(!searchItems.contains { $0.name == "dataview" })
        precondition(URLComponents(url: fixture.recorded()[1], resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "dataview" && $0.value == "info" })
        precondition(track.attributionDetail?.contains("Guest Composer") == true && track.attributionText.contains("Sample Composer")
                     && track.attributionText.contains("https://ccmixter.org/files/sample/9"), "Preserve named collaborators and available upstream sample credits")
        print("PASS official query parameters, seconds, license normalization, same-query cache")

        var forbidden = row; forbidden["license_url"] = "https://creativecommons.org/licenses/by-nc/4.0/"; forbidden["license_name"] = "Attribution"
        var sharealike = row; sharealike["license_url"] = "https://creativecommons.org/licenses/by-sa/4.0/"
        var noDerivatives = row; noDerivatives["license_url"] = "https://creativecommons.org/licenses/by-nd/4.0/"
        var spoof = row; spoof["license_url"] = "https://creativecommons.org.evil.invalid/licenses/by/4.0/"
        var vocal = row; vocal["upload_tags"] = ",instrumental,female_vocals,"
        var zero = row; zero["license_url"] = "https://creativecommons.org/publicdomain/zero/1.0/"; zero["upload_id"] = 18
        let parsed = try OnlineMusicLibrary.parseCCMixter(JSONSerialization.data(withJSONObject: [forbidden, sharealike, noDerivatives, spoof, vocal, row, zero]))
        precondition(parsed.count == 2 && parsed.map(\.license) == ["CC BY 3.0", "CC0 1.0"])
        var insecure = track; insecure.audioURL = URL(string: "http://ccmixter.org/content/fixture.wav")!
        await expect(.invalidURL) { _ = try await OnlineMusicLibrary.download(track: insecure, cacheDirectory: directory.appendingPathComponent("insecure"), configuration: config) }
        var wrongLicense = track; wrongLicense.licenseURL = URL(string: "https://creativecommons.org/licenses/by-nc/3.0/")!
        await expect(.unsupportedLicense) { _ = try await OnlineMusicLibrary.download(track: wrongLicense, cacheDirectory: directory.appendingPathComponent("forbidden"), configuration: config) }
        print("PASS exclusion of NC/ND/SA and spoofed license URLs, HTTPS requirement")

        let cacheRoot = directory.appendingPathComponent("cache")
        let local = try await OnlineMusicLibrary.download(track: track, cacheDirectory: cacheRoot, configuration: config)
        let downloadedData = try Data(contentsOf: local)
        precondition(downloadedData == audio)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: OnlineMusicLibrary.licenseRecordURL(for: local))) as! [String: Any]
        precondition((record["actualDuration"] as? Double ?? 0) > 1.9 && record["sha256"] as? String != nil)
        precondition((record["track"] as? [String: Any])?["artist"] as? String == track.artist)
        let attribution = try String(contentsOf: OnlineMusicLibrary.attributionSidecarURL(for: local), encoding: .utf8)
        precondition(attribution.contains(track.artist) && attribution.contains(track.sourceURL.absoluteString) && attribution.contains(track.licenseURL.absoluteString))
        let requestsBeforeCache = fixture.recorded().count
        let second = try await OnlineMusicLibrary.download(track: track, cacheDirectory: cacheRoot, configuration: config)
        precondition(second == local && fixture.recorded().count == requestsBeforeCache, "Verified cached audio remains usable offline")
        let completedFiles = try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)
        precondition(completedFiles.allSatisfy { !$0.hasPrefix(".incoming") })
        let corrupt = try FileHandle(forWritingTo: local); try corrupt.seekToEnd(); try corrupt.write(contentsOf: Data([0xff])); try corrupt.close()
        let recovered = try await OnlineMusicLibrary.download(track: track, cacheDirectory: cacheRoot, configuration: config)
        let recoveredBytes = try Data(contentsOf: recovered)
        precondition(recoveredBytes == audio, "A corrupt reproducible cache should be validated and downloaded again")
        print("PASS catalog revalidation, PCM decoding, atomic audio/license/credit cache, offline reuse")

        fixture.change { $0.detailRows = [forbidden] }
        await expect(.staleResult) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("stale"), configuration: config) }
        fixture.change { $0.detailRows = [row]; $0.audioReply = .init(body: Data("<html>bad</html>".utf8), mime: "text/html") }
        await expect(.invalidAudio) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("html"), configuration: config) }
        fixture.change { $0.audioReply = .init(body: Data("not an audio file".utf8), mime: "audio/mpeg") }
        await expect(.invalidAudio) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("fake-audio"), configuration: config) }
        fixture.change { $0.audioReply = .init(body: Data([1]), mime: "audio/wav", length: OnlineMusicLibrary.maximumDownloadBytes + 1) }
        await expect(.tooLarge) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("promised-large"), configuration: config) }
        fixture.change { $0.audioReply = .init(body: audio, mime: "audio/wav") }
        await expect(.tooLarge) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("chunked-large"), configuration: config, byteLimit: 1024) }
        let longURL = directory.appendingPathComponent("long.wav")
        try makeLongWave(at: longURL)
        let longAudio = try Data(contentsOf: longURL)
        fixture.change { $0.audioReply = .init(body: longAudio, mime: "audio/wav", length: longAudio.count) }
        await expect(.tooLong) { _ = try await OnlineMusicLibrary.download(track: track, cacheDirectory: directory.appendingPathComponent("actual-too-long"), configuration: config) }
        print("PASS changed license, HTML masquerade, actual decoded duration, declared and streaming size caps")

        fixture.change { $0.audioReply = .init(body: audio, mime: "audio/wav", delay: 0.5) }
        let cancelledRoot = directory.appendingPathComponent("cancelled")
        let before = fixture.recorded().filter { $0.path.hasSuffix("fixture.wav") }.count
        let cancelled = Task { try await OnlineMusicLibrary.download(track: track, cacheDirectory: cancelledRoot, configuration: config) }
        for _ in 0..<200 {
            if fixture.recorded().filter({ $0.path.hasSuffix("fixture.wav") }).count > before { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation should stop the transfer") }
        catch { precondition(error is CancellationError, "Expected cooperative task cancellation: \(error)") }
        let cancelledFiles = (try? FileManager.default.contentsOfDirectory(atPath: cancelledRoot.path)) ?? []
        precondition(cancelledFiles.isEmpty, "Cancellation cannot publish a partial cache or leave temporary audio")
        print("PASS in-flight URLSession cancellation with no published or staging files")

        fixture.reset(audio: audio, row: row)
        fixture.change { $0.searchRows = []; $0.openverseRows = [openverseRow(jamendo: true), openverseRow(jamendo: false)] }
        let fallback = try await OnlineMusicLibrary.search(query: "fallback", configuration: config, useCache: false)
        precondition(fallback.count == 1 && fallback[0].artist == "Commons Composer" && fallback[0].duration == 2)
        precondition(!fallback[0].audioURL.absoluteString.contains("jamendo"))
        fixture.change { $0.searchStatus = 429; $0.openverseStatus = 429 }
        await expect(.rateLimited) { _ = try await OnlineMusicLibrary.search(query: "rate limit", configuration: config, useCache: false) }
        print("PASS Openverse music fallback, millisecond conversion, Jamendo exclusion, clear 429 error")

        if CommandLine.arguments.contains("--online") {
            let live = try await OnlineMusicLibrary.search(query: "ambient")
            precondition(!live.isEmpty, "Official public music search returned no results")
            let piano = try await OnlineMusicLibrary.search(query: "piano")
            precondition(!piano.isEmpty && Set(live.map(\.id)) != Set(piano.map(\.id)), "Different live queries must produce different actual catalog matches")
            print("ONLINE QUERY ambient=\(live.map(\.id).joined(separator: ",")) piano=\(piano.map(\.id).joined(separator: ","))")
            var downloaded: URL?, lastError: Error?
            for choice in live.prefix(3) {
                do {
                    let local = try await OnlineMusicLibrary.download(track: choice)
                    downloaded = local
                    print("ONLINE VERIFIED name=\(choice.name) artist=\(choice.artist) license=\(choice.license) source=\(choice.sourceURL.absoluteString)")
                    print("ONLINE CACHED audio=\(local.path) license=\(OnlineMusicLibrary.licenseRecordURL(for: local).path)")
                    break
                } catch { lastError = error }
            }
            if downloaded == nil { throw lastError ?? OnlineMusicError.invalidAudio }
            print("PASS live official-catalog search and licensed audio download; no playback")
        }
    }
    private static func expect(_ expected: OnlineMusicError, operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch { precondition((error as? OnlineMusicError)?.errorDescription == expected.errorDescription, "Expected \(expected), received \(error)") }
    }
    private static func ccRow(size: Int) -> [String: Any] {
        ["upload_id": 17, "upload_name": "海边测试曲", "user_real_name": "Fixture Composer", "file_page_url": "https://ccmixter.org/files/fixture/17",
         "license_url": "http://creativecommons.org/licenses/by/3.0/", "upload_extra": ["nsfw": false, "featuring": "Guest Composer"],
         "remix_parents": [["upload_name": "Original Sample", "user_real_name": "Sample Composer", "file_page_url": "https://ccmixter.org/files/sample/9"]],
         "files": [["file_id": 199, "download_url": "https://ccmixter.org/content/fixture.wav", "file_rawsize": size, "file_nicname": "wav",
                    "file_format_info": ["media-type": "audio", "ps": "0:02"]]]]
    }
    private static func openverseRow(jamendo: Bool) -> [String: Any] {
        ["id": "d7dab313-012d-4138-8081-c444ed553140", "title": "Commons music", "creator": "Commons Composer", "category": "music", "mature": false,
         "source": jamendo ? "jamendo" : "wikimedia_audio", "provider": jamendo ? "jamendo" : "wikimedia_audio", "duration": 2000,
         "url": jamendo ? "https://prod-1.storage.jamendo.com/test.mp3" : "https://upload.wikimedia.org/commons/fixture.wav",
         "foreign_landing_url": "https://commons.wikimedia.org/wiki/File:Fixture.wav", "license": "cc0", "license_url": "https://creativecommons.org/publicdomain/zero/1.0/"]
    }
    private static func makeWave(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 22050) * 0.08) }
        try file.write(from: buffer)
    }
    private static func makeLongWave(at url: URL) throws {
        // A small-rate, real 901-second PCM file; API fixture still claims only two seconds.
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        for _ in 0..<901 { try file.write(from: buffer) }
    }
}
