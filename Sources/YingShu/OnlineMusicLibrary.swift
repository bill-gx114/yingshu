import AVFoundation
import CryptoKit
import Foundation

/// A catalog result is a license declaration from the source, not an ownership guarantee.
/// Only CC0 and unqualified CC BY licenses enter this library.
struct OnlineMusicTrack: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var artist: String
    var audioURL: URL
    var sourceURL: URL
    var license: String
    var licenseURL: URL
    /// Seconds. Some catalogs do not publish a duration; the downloaded audio is always measured.
    var duration: Double?
    /// Source-provided collaborators or attribution. This may not describe the complete sample chain.
    var attributionDetail: String? = nil

    var attributionText: String {
        var lines = ["《\(name)》— \(artist)", "来源：\(sourceURL.absoluteString)", "许可：\(license) · \(licenseURL.absoluteString)"]
        if let attributionDetail, !attributionDetail.isEmpty { lines.append(attributionDetail) }
        lines.append("发布前请打开来源页核对完整署名与采样作者；本记录来自曲库元数据，未核验完整采样链。")
        return lines.joined(separator: "\n")
    }
}

enum OnlineMusicError: LocalizedError {
    case invalidQuery, invalidURL, unsupportedLicense, staleResult, invalidResponse, invalidAudio
    case tooLarge, tooLong, rateLimited, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "请输入 1–120 个字符的音乐关键词。"
        case .invalidURL: return "音乐来源未提供有效的 HTTPS 地址，请选择其它结果。"
        case .unsupportedLicense: return "这首音乐没有可核验的 CC0 或 CC BY 许可，无法下载。"
        case .staleResult: return "音乐来源信息已经变化，请重新搜索后选择。"
        case .invalidResponse: return "音乐来源返回了无法读取的数据，请稍后重试。"
        case .invalidAudio: return "下载内容不是可播放的音频，请选择其它音乐。"
        case .tooLarge: return "这首音乐超过 60 MB 下载上限，请选择其它结果。"
        case .tooLong: return "这首音乐超过 15 分钟时长上限，请选择其它结果。"
        case .rateLimited: return "音乐来源暂时限制了查询频率，请稍后再搜索。"
        case .unavailable(let source): return "暂时无法连接\(source)，请检查网络后重试。"
        }
    }
}

enum OnlineMusicLibrary {
    // Official public APIs, no embedded application keys and no streaming-service extraction.
    // https://ccmixter.org/query-api · https://ccmixter.org/about/attributionGenerator
    // https://api.openverse.org/v1/ · https://developer.jamendo.com/v3.0/tracks
    // Jamendo results are excluded: its current audiodownload_allowed needs a registered client ID.
    static let maximumDownloadBytes = 60 * 1024 * 1024
    static let maximumDuration: Double = 15 * 60
    private static let searchCache = MusicQueryCache()

    static func search(query: String) async throws -> [OnlineMusicTrack] {
        try await search(query: query, configuration: .ephemeral, useCache: true)
    }

    static func download(track: OnlineMusicTrack) async throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try await download(track: track, cacheDirectory: support.appendingPathComponent("YingShu/OnlineMusic", isDirectory: true), configuration: .ephemeral)
    }

    /// The ready-to-copy credit travels with the cached audio. Exporters may copy this file.
    static func attributionSidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingLastPathComponent().appendingPathComponent("ATTRIBUTION.txt")
    }
    static func licenseRecordURL(for audioURL: URL) -> URL {
        audioURL.deletingLastPathComponent().appendingPathComponent("license.json")
    }

    // Internal seams let checks use deterministic HTTPS URLProtocol responses without public requests.
    static func search(query: String, configuration: URLSessionConfiguration, useCache: Bool) async throws -> [OnlineMusicTrack] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 120 else { throw OnlineMusicError.invalidQuery }
        let cacheKey = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if useCache, let cached = await searchCache.result(for: cacheKey) { try Task.checkCancellation(); return cached }
        // A bounded one-page search requested by the editor. No crawler, pagination loop, or auto retry.
        if useCache { try await searchCache.waitForTurn() }
        var firstError: Error?
        do {
            let result = try await ccMixter(query: query, configuration: configuration)
            if !result.isEmpty {
                if useCache { await searchCache.store(result, for: cacheKey) }
                try Task.checkCancellation(); return result
            }
        } catch {
            try Task.checkCancellation(); firstError = error
        }
        do {
            let result = try await openverse(query: query, configuration: configuration)
            if result.isEmpty, let firstError { throw firstError }
            if useCache { await searchCache.store(result, for: cacheKey) }
            try Task.checkCancellation(); return result
        } catch {
            try Task.checkCancellation(); throw firstError ?? error
        }
    }

    static func download(track: OnlineMusicTrack, cacheDirectory: URL, configuration: URLSessionConfiguration,
                         byteLimit: Int = maximumDownloadBytes) async throws -> URL {
        try Task.checkCancellation()
        guard isHTTPS(track.audioURL), isHTTPS(track.sourceURL) else { throw OnlineMusicError.invalidURL }
        guard let accepted = acceptedLicense(track.licenseURL), accepted.name == track.license else { throw OnlineMusicError.unsupportedLicense }
        if let duration = track.duration, !duration.isFinite || duration <= 0 || duration > maximumDuration { throw OnlineMusicError.tooLong }
        let keyEncoder = JSONEncoder(); keyEncoder.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: try keyEncoder.encode(track)).map { String(format: "%02x", $0) }.joined()
        let finalDirectory = cacheDirectory.appendingPathComponent(key, isDirectory: true)
        do { if let existing = try await cached(track: track, directory: finalDirectory, byteLimit: byteLimit) { return existing } }
        catch OnlineMusicError.invalidAudio {
            // This directory contains only a reproducible download, never the user's source files.
            try FileManager.default.removeItem(at: finalDirectory)
        }

        // Recheck official catalog metadata immediately before a new transfer. A crafted/stale project
        // cannot turn an arbitrary remote MP3 into an apparently licensed catalog result.
        try await revalidate(track, configuration: configuration)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let staging = cacheDirectory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let ext = supportedExtension(track.audioURL.pathExtension) ?? "mp3"
        let audio = staging.appendingPathComponent("audio.\(ext)")
        var audioRequest = request(track.audioURL)
        // The public ccMixter content server checks the source-page referrer for its
        // explicitly licensed API download links. Preserve that catalog provenance.
        if isCCMixter(track.audioURL) { audioRequest.setValue(track.sourceURL.absoluteString, forHTTPHeaderField: "Referer") }
        let result = try await MusicTransfer(limit: byteLimit, kind: .audio, outputURL: audio)
            .run(request: audioRequest, configuration: configuration)
        try Task.checkCancellation()
        let measuredDuration = try await validateAudio(audio)
        let hash = try checksum(audio)
        let record = MusicLicenseRecord(version: 1, track: track, downloadedAt: Date(), actualDuration: measuredDuration,
                                        fileSize: result.byteCount, sha256: hash, audioFilename: audio.lastPathComponent)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: staging.appendingPathComponent("license.json"), options: .atomic)
        let attribution = track.attributionText + "\n\n发布说明：CC BY 音乐需保留以上署名及链接；若在视频中截取、循环或调整音量，请注明相应修改。\n下载时间：\(ISO8601DateFormatter().string(from: record.downloadedAt))\n"
        try Data(attribution.utf8).write(to: staging.appendingPathComponent("ATTRIBUTION.txt"), options: .atomic)
        try Task.checkCancellation()
        // Publish the audio and both license records together through a directory rename on the same volume.
        do { try FileManager.default.moveItem(at: staging, to: finalDirectory) }
        catch {
            // Another simultaneous request may have completed this same track first.
            if let existing = try await cached(track: track, directory: finalDirectory, byteLimit: byteLimit) { return existing }
            throw error
        }
        return finalDirectory.appendingPathComponent(audio.lastPathComponent)
    }

    private static func ccMixter(query: String, configuration: URLSessionConfiguration) async throws -> [OnlineMusicTrack] {
        // ccHost duplicates its JSON body into an X-JSON HTTP header. Large pages can exceed
        // client/proxy header limits, so deliberately keep this first-page request small.
        let url = endpoint("https://ccmixter.org/api/query", ["f": "json", "limit": "6", "lic": "by,zero", "reqtags": "instrumental", "search": query, "search_type": "all"])
        let matches = try parseCCMixter(await json(url, configuration: configuration))
        guard !matches.isEmpty else { return [] }
        // The info dataview is designed for a single upload. Using it for the search itself
        // changes its ordering/limit. Search normally, then fetch at most six explicit IDs,
        // with at most three metadata requests in flight to preserve known sample credits.
        var enriched = [OnlineMusicTrack?](repeating: nil, count: matches.count)
        var throttled = false
        for start in stride(from: 0, to: matches.count, by: 3) {
            let batch = start..<min(start + 3, matches.count)
            try await withThrowingTaskGroup(of: (Int, OnlineMusicTrack?, Bool).self) { group in
                for index in batch {
                    let track = matches[index]
                    group.addTask {
                        do {
                            let uploadID = String(track.id.split(separator: "-")[1])
                            let details = try await info(uploadID: uploadID, configuration: configuration)
                            return (index, details.first { sameIdentity($0, track) }, false)
                        } catch {
                            try Task.checkCancellation()
                            if let issue = error as? OnlineMusicError, case .rateLimited = issue { return (index, nil, true) }
                            return (index, nil, false)
                        }
                    }
                }
                for try await (index, detail, limited) in group { enriched[index] = detail; throttled = throttled || limited }
            }
        }
        let result = enriched.compactMap { $0 }
        guard !result.isEmpty else { throw throttled ? OnlineMusicError.rateLimited : OnlineMusicError.unavailable("ccMixter 的许可详情") }
        return result
    }
    private static func openverse(query: String, configuration: URLSessionConfiguration) async throws -> [OnlineMusicTrack] {
        let url = endpoint("https://api.openverse.org/v1/audio/", ["q": query, "license": "cc0,by", "category": "music", "excluded_source": "jamendo", "mature": "false", "page_size": "20"])
        let payload = try await json(url, configuration: configuration)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let rows = object["results"] as? [[String: Any]] else { throw OnlineMusicError.invalidResponse }
        return rows.compactMap(parseOpenverse)
    }
    private static func revalidate(_ track: OnlineMusicTrack, configuration: URLSessionConfiguration) async throws {
        let parts = track.id.split(separator: "-")
        let current: [OnlineMusicTrack]
        if parts.count == 3, parts[0] == "ccmixter", Int(parts[1]) != nil, Int(parts[2]) != nil {
            current = try await info(uploadID: String(parts[1]), configuration: configuration)
        } else if track.id.hasPrefix("openverse-"), let id = UUID(uuidString: String(track.id.dropFirst("openverse-".count))) {
            let url = URL(string: "https://api.openverse.org/v1/audio/\(id.uuidString.lowercased())/")!
            guard let row = try JSONSerialization.jsonObject(with: await json(url, configuration: configuration)) as? [String: Any] else { throw OnlineMusicError.invalidResponse }
            current = [parseOpenverse(row)].compactMap { $0 }
        } else { throw OnlineMusicError.staleResult }
        guard current.contains(where: { sameIdentity($0, track) && $0.attributionDetail == track.attributionDetail }) else {
            await searchCache.invalidate(trackID: track.id)
            throw OnlineMusicError.staleResult
        }
    }
    private static func info(uploadID: String, configuration: URLSessionConfiguration) async throws -> [OnlineMusicTrack] {
        let url = endpoint("https://ccmixter.org/api/query", ["f": "json", "dataview": "info", "ids": uploadID, "lic": "by,zero", "limit": "1"])
        return try parseCCMixter(await json(url, configuration: configuration), includeAllFiles: true)
    }
    private static func sameIdentity(_ a: OnlineMusicTrack, _ b: OnlineMusicTrack) -> Bool {
        a.id == b.id && a.audioURL == b.audioURL && a.sourceURL == b.sourceURL && a.licenseURL == b.licenseURL &&
        a.license == b.license && a.name == b.name && a.artist == b.artist
    }

    static func parseCCMixter(_ data: Data, includeAllFiles: Bool = false) throws -> [OnlineMusicTrack] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw OnlineMusicError.invalidResponse }
        var seen = Set<String>(), tracks: [OnlineMusicTrack] = []
        for row in rows {
            guard let uploadID = integer(row["upload_id"]), let name = nonempty(row["upload_name"]),
                  let artist = nonempty(row["user_real_name"]) ?? nonempty(row["user_name"]),
                  let rawLicense = row["license_url"] as? String, let licenseURL = URL(string: rawLicense),
                  let license = acceptedLicense(licenseURL), let source = stringURL(row["file_page_url"]),
                  isCCMixter(source), let files = row["files"] as? [[String: Any]],
                  (row["upload_extra"] as? [String: Any])?["nsfw"] as? Bool != true else { continue }
            let tags = Set((row["upload_tags"] as? String ?? "").lowercased().split(separator: ",").map(String.init))
            if !includeAllFiles, !tags.isDisjoint(with: ["female_vocals", "male_vocals", "vocals", "rap", "a_cappella", "acappella", "spoken_word"]) { continue }
            for file in files {
                guard let fileID = integer(file["file_id"]), let url = stringURL(file["download_url"]), isCCMixter(url),
                      let format = file["file_format_info"] as? [String: Any], format["media-type"] as? String == "audio",
                      supportedExtension(url.pathExtension) != nil,
                      integer(file["file_rawsize"]).map({ $0 > 0 && $0 <= maximumDownloadBytes }) ?? true else { continue }
                let type = (file["file_extra"] as? [String: Any])?["type"] as? String
                if !includeAllFiles, type == "samples" || (file["file_nicname"] as? String)?.lowercased() == "sample" { continue }
                let duration = seconds(format["ps"] as? String)
                if let duration, duration <= 0 || duration > maximumDuration { continue }
                let id = "ccmixter-\(uploadID)-\(fileID)"
                if seen.insert(id).inserted {
                    tracks.append(OnlineMusicTrack(id: id, name: name, artist: artist, audioURL: url, sourceURL: source,
                                                   license: license.name, licenseURL: license.url, duration: duration,
                                                   attributionDetail: ccMixterCredits(row)))
                }
                if !includeAllFiles { break }
            }
        }
        return tracks
    }
    private static func ccMixterCredits(_ row: [String: Any]) -> String? {
        var lines: [String] = []
        if let featuring = nonempty((row["upload_extra"] as? [String: Any])?["featuring"]) { lines.append("Featuring：\(featuring)") }
        if let parents = row["remix_parents"] as? [[String: Any]] {
            for parent in parents.prefix(16) {
                guard let name = nonempty(parent["upload_name"]), let artist = nonempty(parent["user_real_name"]),
                      let source = stringURL(parent["file_page_url"]), isCCMixter(source) else { continue }
                lines.append("采样来源：《\(name)》— \(artist) · \(source.absoluteString)")
            }
        }
        return lines.isEmpty ? nil : String(lines.joined(separator: "\n").prefix(6000))
    }
    private static func parseOpenverse(_ row: [String: Any]) -> OnlineMusicTrack? {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil, let name = nonempty(row["title"]), let artist = nonempty(row["creator"]),
              let audio = stringURL(row["url"]), let source = stringURL(row["foreign_landing_url"]),
              let licenseURL = stringURL(row["license_url"]), let license = acceptedLicense(licenseURL),
              row["category"] as? String == "music", row["mature"] as? Bool != true,
              !["jamendo"].contains((row["source"] as? String ?? "").lowercased()),
              !["jamendo"].contains((row["provider"] as? String ?? "").lowercased()),
              !audio.host!.lowercased().contains("jamendo.com"),
              !source.host!.lowercased().contains("jamendo.com"),
              ((row["license"] as? String == "by" && license.name.hasPrefix("CC BY ")) ||
               (row["license"] as? String == "cc0" && license.name == "CC0 1.0")) else { return nil }
        let duration = (row["duration"] as? NSNumber).map { $0.doubleValue / 1000 }
        if let duration, !duration.isFinite || duration <= 0 || duration > maximumDuration { return nil }
        if let size = row["filesize"] as? NSNumber, size.intValue > maximumDownloadBytes { return nil }
        return OnlineMusicTrack(id: "openverse-\(id.lowercased())", name: name, artist: artist, audioURL: audio, sourceURL: source,
                                license: license.name, licenseURL: license.url, duration: duration,
                                attributionDetail: nonempty(row["attribution"]))
    }

    static func acceptedLicense(_ input: URL) -> (name: String, url: URL)? {
        guard ["http", "https"].contains(input.scheme?.lowercased() ?? ""),
              ["creativecommons.org", "www.creativecommons.org"].contains(input.host?.lowercased() ?? ""),
              input.user == nil, input.password == nil, input.port == nil, input.query == nil, input.fragment == nil else { return nil }
        let components = input.path.lowercased().split(separator: "/").map(String.init)
        if components == ["publicdomain", "zero", "1.0"] {
            return ("CC0 1.0", URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!)
        }
        guard components.count == 3 || components.count == 4,
              components[0] == "licenses", components[1] == "by", ["1.0", "2.0", "2.5", "3.0", "4.0"].contains(components[2]) else { return nil }
        if components.count == 4, components[3].range(of: "^[a-z]{2,3}$", options: .regularExpression) == nil { return nil }
        return ("CC BY \(components[2])", URL(string: "https://creativecommons.org/\(components.joined(separator: "/"))/")!)
    }
    private static func cached(track: OnlineMusicTrack, directory: URL, byteLimit: Int) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let data = try? Data(contentsOf: directory.appendingPathComponent("license.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data, let record = try? decoder.decode(MusicLicenseRecord.self, from: data), record.version == 1, record.track == track,
              record.fileSize > 0, record.fileSize <= byteLimit, record.audioFilename == URL(fileURLWithPath: record.audioFilename).lastPathComponent,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("ATTRIBUTION.txt").path) else { throw OnlineMusicError.invalidAudio }
        let audio = directory.appendingPathComponent(record.audioFilename)
        guard FileManager.default.fileExists(atPath: audio.path) else { throw OnlineMusicError.invalidAudio }
        guard let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == record.fileSize,
              try checksum(audio) == record.sha256 else { throw OnlineMusicError.invalidAudio }
        _ = try await validateAudio(audio)
        try Task.checkCancellation(); return audio
    }
    private static func validateAudio(_ url: URL) async throws -> Double {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            do {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let protected = try await asset.load(.hasProtectedContent)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard playable, !protected, !tracks.isEmpty, duration.isFinite, duration > 0 else { throw OnlineMusicError.invalidAudio }
                guard duration <= maximumDuration else { throw OnlineMusicError.tooLong }
                // Decode a bounded block, not just an extension/container check.
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(2048, file.length))) else { throw OnlineMusicError.invalidAudio }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw OnlineMusicError.invalidAudio }
                try Task.checkCancellation(); return duration
            } catch {
                try Task.checkCancellation()
                if let known = error as? OnlineMusicError { throw known }
                throw OnlineMusicError.invalidAudio
            }
        } onCancel: { asset.cancelLoading() }
    }
    private static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 128 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func json(_ url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        try await MusicTransfer(limit: 2 * 1024 * 1024, kind: .json, outputURL: nil).run(request: request(url), configuration: configuration).data
    }
    private static func endpoint(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return components.url!
    }
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("YingShu/1.0 (licensed music search)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, audio/*, application/octet-stream;q=0.8, text/plain;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }
    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local") && !host.contains(":") &&
            host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
    }
    private static func isCCMixter(_ url: URL) -> Bool { isHTTPS(url) && ["ccmixter.org", "www.ccmixter.org"].contains(url.host?.lowercased() ?? "") }
    private static func stringURL(_ value: Any?) -> URL? { guard let text = value as? String, let url = URL(string: text), isHTTPS(url) else { return nil }; return url }
    private static func nonempty(_ value: Any?) -> String? { guard let text = value as? String else { return nil }; let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed }
    private static func integer(_ value: Any?) -> Int? { if let number = value as? NSNumber { return number.intValue }; if let text = value as? String { return Int(text) }; return nil }
    private static func supportedExtension(_ ext: String) -> String? { let ext = ext.lowercased(); return ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"].contains(ext) ? ext : nil }
    private static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let pieces = text.split(separator: ":").compactMap { Double($0) }
        guard !pieces.isEmpty, pieces.count <= 3, pieces.count == text.split(separator: ":").count else { return nil }
        return pieces.reduce(0) { $0 * 60 + $1 }
    }
}

private struct MusicLicenseRecord: Codable {
    var version: Int
    var track: OnlineMusicTrack
    var downloadedAt: Date
    var actualDuration: Double
    var fileSize: Int
    var sha256: String
    var audioFilename: String
}

private actor MusicQueryCache {
    private var results: [String: (date: Date, tracks: [OnlineMusicTrack])] = [:]
    private var nextQuery = Date.distantPast
    func result(for query: String) -> [OnlineMusicTrack]? {
        guard let entry = results[query], Date().timeIntervalSince(entry.date) < 600 else { return nil }; return entry.tracks
    }
    func store(_ tracks: [OnlineMusicTrack], for query: String) {
        results[query] = (Date(), tracks)
        if results.count > 40, let oldest = results.min(by: { $0.value.date < $1.value.date })?.key { results.removeValue(forKey: oldest) }
    }
    func invalidate(trackID: String) {
        for query in Array(results.keys) where results[query]?.tracks.contains(where: { $0.id == trackID }) == true { results.removeValue(forKey: query) }
    }
    func waitForTurn() async throws {
        let start = max(Date(), nextQuery); nextQuery = start.addingTimeInterval(1)
        let delay = start.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}

/// Bounded streaming to disk/memory; checks headers before accepting bytes, rejects HTTPS downgrades,
/// and couples Swift task cancellation to the actual URLSession task.
private final class MusicTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Kind { case json, audio }
    struct Result { var data: Data; var byteCount: Int }
    private let limit: Int, kind: Kind, outputURL: URL?
    private let lock = NSLock()
    private var task: URLSessionDataTask?, session: URLSession?, continuation: CheckedContinuation<Result, Error>?
    private var handle: FileHandle?, data = Data(), count = 0, redirects = 0
    private var completed = false, cancelled = false
    init(limit: Int, kind: Kind, outputURL: URL?) { self.limit = limit; self.kind = kind; self.outputURL = outputURL }
    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> Result {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    if let outputURL {
                        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw OnlineMusicError.invalidAudio }
                        handle = try FileHandle(forWritingTo: outputURL)
                    }
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = kind == .audio ? 180 : 40
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    self.session = session; task = session.dataTask(with: request)
                    let started = task; lock.unlock(); started?.resume()
                } catch { lock.unlock(); finish(.failure(error)) }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel(); finish(.failure(CancellationError()))
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let callback = continuation, session = session, handle = handle
        continuation = nil; self.session = nil; self.handle = nil; task = nil
        lock.unlock()
        try? handle?.close(); session?.invalidateAndCancel(); callback?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, OnlineMusicLibrary.isHTTPS(url) else {
            completionHandler(nil); finish(.failure(OnlineMusicError.invalidURL)); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, OnlineMusicLibrary.isHTTPS(url) else {
            completionHandler(.cancel); finish(.failure(OnlineMusicError.invalidResponse)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(http.statusCode == 429 ? OnlineMusicError.rateLimited : OnlineMusicError.unavailable(url.host ?? "音乐来源"))); return
        }
        guard response.expectedContentLength <= limit else { completionHandler(.cancel); finish(.failure(kind == .json ? OnlineMusicError.invalidResponse : OnlineMusicError.tooLarge)); return }
        let mime = (response.mimeType ?? "").lowercased()
        let valid = kind == .json ? (mime == "application/json" || mime == "text/plain" || mime.hasSuffix("+json")) : (mime.hasPrefix("audio/") || ["application/octet-stream", "binary/octet-stream", "application/ogg"].contains(mime))
        guard valid else { completionHandler(.cancel); finish(.failure(kind == .json ? OnlineMusicError.invalidResponse : OnlineMusicError.invalidAudio)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard incoming.count <= limit - count else { lock.unlock(); finish(.failure(kind == .json ? OnlineMusicError.invalidResponse : OnlineMusicError.tooLarge)); return }
        do {
            if let handle { try handle.write(contentsOf: incoming) } else { data.append(incoming) }
            count += incoming.count; lock.unlock()
        } catch { lock.unlock(); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            let failure: Error = wasCancelled || (error as? URLError)?.code == .cancelled ? CancellationError() : OnlineMusicError.unavailable(task.originalRequest?.url?.host ?? "音乐来源")
            finish(.failure(failure))
        } else {
            lock.lock(); let result = Result(data: data, byteCount: count); lock.unlock()
            if result.byteCount == 0 { finish(.failure(OnlineMusicError.invalidResponse)) } else { finish(.success(result)) }
        }
    }
}
