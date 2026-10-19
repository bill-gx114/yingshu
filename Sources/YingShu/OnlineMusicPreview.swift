import AVFoundation
import Foundation

struct MusicPreviewClip: Equatable, Sendable {
    let url: URL
    let directory: URL
    let duration: Double
}

enum OnlineMusicPreviewError: LocalizedError, Equatable {
    case invalidURL, unsupportedFormat, rangeUnavailable, invalidResponse, tooLarge, invalidAudio, tooShort, rateLimited, unavailable, bufferTimeout, sourceChanged
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "这首音乐没有有效的 HTTPS 试听地址，请打开来源页试听。"
        case .unsupportedFormat: return "目前支持 MP3 片段试听，请打开来源页试听其它格式。"
        case .rangeUnavailable: return "音乐来源不支持有界片段请求，请打开来源页试听。"
        case .invalidResponse: return "音乐来源返回的片段不完整，请重试或打开来源页试听。"
        case .tooLarge: return "音乐来源返回的内容超过 2 MiB 试听上限，已停止传输。"
        case .invalidAudio: return "无法解码这段试听音频，请打开来源页试听。"
        case .tooShort: return "这段音乐的可用试听不足一秒，请打开来源页试听。"
        case .rateLimited: return "音乐来源暂时限制试听频率，请稍后重试。"
        case .unavailable: return "暂时无法加载试听，请检查网络或打开来源页。"
        case .bufferTimeout: return "试听等待超时，请检查网络或打开来源页。"
        case .sourceChanged: return "来源音频已经更新，请再次点击试听。"
        }
    }
}

/// Downloads a bounded prefix into a unique temporary directory, then decodes at most twenty
/// seconds into a self-contained local WAV. It never plays audio or writes a project/music cache.
enum OnlineMusicPreview {
    static let maximumNetworkBytes = 2 * 1024 * 1024
    static let targetDuration: Double = 20
    private static let directoryPrefix = "YingShuMusicPreview-"

    static func prepare(track: OnlineMusicTrack) async throws -> MusicPreviewClip {
        try await prepare(track: track, configuration: .ephemeral, temporaryRoot: FileManager.default.temporaryDirectory)
    }

    static func remove(_ clip: MusicPreviewClip) {
        let directory = clip.directory.standardizedFileURL
        // Only remove a directory made for this disposable preview, never an arbitrary URL.
        guard directory.lastPathComponent.hasPrefix(directoryPrefix),
              clip.url.deletingLastPathComponent().standardizedFileURL == directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // Deterministic HTTPS fixtures can supply their own URLProtocol and temporary root.
    static func prepare(track: OnlineMusicTrack, configuration: URLSessionConfiguration,
                        temporaryRoot: URL, byteLimit: Int = maximumNetworkBytes) async throws -> MusicPreviewClip {
        try Task.checkCancellation()
        guard isHTTPS(track.audioURL), isHTTPS(track.sourceURL) else { throw OnlineMusicPreviewError.invalidURL }
        let ext = track.audioURL.pathExtension.lowercased()
        guard ext.isEmpty || ext == "mp3" else { throw OnlineMusicPreviewError.unsupportedFormat }
        guard byteLimit > 0, byteLimit <= maximumNetworkBytes else { throw OnlineMusicPreviewError.tooLarge }
        let directory = temporaryRoot.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: directory) } }
        let prefix = directory.appendingPathComponent("prefix.mp3")
        var request = URLRequest(url: track.audioURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("YingShu/1.0 (bounded licensed music preview)", forHTTPHeaderField: "User-Agent")
        request.setValue(track.sourceURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("audio/mpeg, audio/mp3, application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
        try await PreviewPrefixTransfer(outputURL: prefix, byteLimit: byteLimit, sourceURL: track.sourceURL)
            .run(request: request, configuration: configuration)
        try Task.checkCancellation()
        let output = directory.appendingPathComponent("preview.wav")
        try decodePrefix(prefix, into: output)
        try FileManager.default.removeItem(at: prefix)
        let duration = try await validateOutput(output)
        try Task.checkCancellation()
        published = true
        return MusicPreviewClip(url: output, directory: directory, duration: duration)
    }

    private static func decodePrefix(_ prefix: URL, into output: URL) throws {
        try Task.checkCancellation()
        do {
            let input = try AVAudioFile(forReading: prefix, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = input.processingFormat
            guard format.sampleRate.isFinite, (8_000...96_000).contains(format.sampleRate), (1...2).contains(format.channelCount) else {
                throw OnlineMusicPreviewError.unsupportedFormat
            }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                          AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                          AVLinearPCMIsNonInterleaved: false]
            let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw OnlineMusicPreviewError.invalidAudio }
            let targetFrames = AVAudioFramePosition((format.sampleRate * targetDuration).rounded(.down))
            var written: AVAudioFramePosition = 0
            while written < targetFrames {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(4096, targetFrames - written))
                do { try input.read(into: buffer, frameCount: frames) }
                catch {
                    // A byte prefix can end in an incomplete MP3 frame. Keep only already decoded
                    // audio; a self-contained output is checked again before exposing it to AVPlayer.
                    if Double(written) / format.sampleRate >= 1 { break }
                    throw OnlineMusicPreviewError.invalidAudio
                }
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
            guard Double(written) / format.sampleRate >= 1 else { throw OnlineMusicPreviewError.tooShort }
        } catch {
            try Task.checkCancellation()
            if let known = error as? OnlineMusicPreviewError { throw known }
            throw OnlineMusicPreviewError.invalidAudio
        }
    }

    private static func validateOutput(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            do {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard playable, !tracks.isEmpty, duration.isFinite, duration >= 1, duration <= targetDuration + 0.001 else {
                    throw OnlineMusicPreviewError.invalidAudio
                }
                let decoded = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 1024) else { throw OnlineMusicPreviewError.invalidAudio }
                try decoded.read(into: buffer)
                guard buffer.frameLength > 0 else { throw OnlineMusicPreviewError.invalidAudio }
                try Task.checkCancellation(); return duration
            } catch {
                try Task.checkCancellation()
                if let known = error as? OnlineMusicPreviewError { throw known }
                throw OnlineMusicPreviewError.invalidAudio
            }
        } onCancel: { asset.cancelLoading() }
    }

    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local") && !host.contains(":") &&
            host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
    }
}

/// Rejects ignored/malformed ranges at headers rather than ever falling back to a complete song.
/// See RFC 9110 §14 and Apple's URLSessionDataDelegate response-disposition API.
private final class PreviewPrefixTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let outputURL: URL, sourceURL: URL, byteLimit: Int
    private let lock = NSLock()
    private var task: URLSessionDataTask?, session: URLSession?, continuation: CheckedContinuation<Void, Error>?, handle: FileHandle?
    private var completed = false, cancelled = false, count = 0, expectedCount = 0, redirects = 0
    init(outputURL: URL, byteLimit: Int, sourceURL: URL) { self.outputURL = outputURL; self.byteLimit = byteLimit; self.sourceURL = sourceURL }

    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw OnlineMusicPreviewError.invalidAudio }
                    handle = try FileHandle(forWritingTo: outputURL)
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    self.session = session; task = session.dataTask(with: request)
                    let started = task; lock.unlock(); started?.resume()
                } catch { lock.unlock(); finish(.failure(error)) }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel(); finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Void, Error>) {
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
        guard redirects <= 3, let url = request.url, OnlineMusicPreview.isHTTPS(url) else {
            completionHandler(nil); finish(.failure(OnlineMusicPreviewError.invalidURL)); return
        }
        var redirected = request
        redirected.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirected.setValue(sourceURL.absoluteString, forHTTPHeaderField: "Referer")
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, OnlineMusicPreview.isHTTPS(url) else {
            completionHandler(.cancel); finish(.failure(OnlineMusicPreviewError.invalidResponse)); return
        }
        guard http.statusCode == 206 else {
            completionHandler(.cancel)
            let error: OnlineMusicPreviewError = http.statusCode == 200 || http.statusCode == 416 ? .rangeUnavailable : (http.statusCode == 429 ? .rateLimited : .unavailable)
            finish(.failure(error)); return
        }
        let mime = (response.mimeType ?? "").lowercased()
        guard ["audio/mpeg", "audio/mp3", "audio/x-mp3", "audio/mpeg3", "application/octet-stream", "binary/octet-stream"].contains(mime) else {
            completionHandler(.cancel); finish(.failure(OnlineMusicPreviewError.unsupportedFormat)); return
        }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity", let value = http.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseRange(value) else {
            completionHandler(.cancel); finish(.failure(OnlineMusicPreviewError.invalidResponse)); return
        }
        guard range.start == 0, range.end >= 0, range.end < byteLimit else {
            completionHandler(.cancel); finish(.failure(OnlineMusicPreviewError.tooLarge)); return
        }
        let declared = range.end + 1
        guard (range.total == nil || range.total! > range.end),
              response.expectedContentLength < 0 || response.expectedContentLength == declared else {
            completionHandler(.cancel); finish(.failure(OnlineMusicPreviewError.invalidResponse)); return
        }
        lock.lock(); expectedCount = declared; lock.unlock()
        completionHandler(.allow)
    }
    private static func parseRange(_ value: String) -> (start: Int, end: Int, total: Int?)? {
        let expression = try! NSRegularExpression(pattern: "^bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)$", options: .caseInsensitive)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let first = Range(match.range(at: 1), in: value), let last = Range(match.range(at: 2), in: value),
              let totalRange = Range(match.range(at: 3), in: value), let start = Int(value[first]), let end = Int(value[last]) else { return nil }
        let totalString = String(value[totalRange])
        guard totalString == "*" || Int(totalString) != nil else { return nil }
        return (start, end, Int(totalString))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard expectedCount > 0, data.count <= byteLimit - count, data.count <= expectedCount - count else {
            lock.unlock(); finish(.failure(OnlineMusicPreviewError.tooLarge)); return
        }
        do {
            try handle?.write(contentsOf: data); count += data.count
            let receivedAll = count == expectedCount
            lock.unlock()
            // Cancel the actual network task as soon as the requested prefix is complete.
            if receivedAll { finish(.success(())) }
        } catch { lock.unlock(); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            finish(.failure(wasCancelled || (error as? URLError)?.code == .cancelled ? CancellationError() : OnlineMusicPreviewError.unavailable))
        } else {
            lock.lock(); let valid = count > 0 && count == expectedCount; lock.unlock()
            finish(valid ? .success(()) : .failure(OnlineMusicPreviewError.invalidResponse))
        }
    }
}
