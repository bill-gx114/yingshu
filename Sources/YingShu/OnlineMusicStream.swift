import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct MusicPreviewStreamMetrics: Sendable {
    var receivedBytes = 0
    var firstByteDelay: TimeInterval?
    var networkFinished = false
    var fromMemoryCache = false
    var isCancelled = false
    var failureMessage: String?
    var deliveredBytes: Int { receivedBytes }
    var firstByteSeconds: TimeInterval? { firstByteDelay }
    var cacheHit: Bool { fromMemoryCache }
}

extension OnlineMusicPreview {
    /// Creates the item immediately. The owner chooses when/how to play it and retains the session.
    @MainActor static func stream(track: OnlineMusicTrack) throws -> OnlineMusicPreviewSession {
        try OnlineMusicPreviewSession(track: track)
    }
    @MainActor static func stream(track: OnlineMusicTrack, configuration: URLSessionConfiguration) throws -> OnlineMusicPreviewSession {
        try OnlineMusicPreviewSession(track: track, configuration: configuration)
    }
}

/// Uses only the documented AVAssetResourceLoader delegate APIs to provide progressively received
/// MP3 bytes. No opaque AVURLAsset HTTP-header options, whole-prefix wait, conversion, or disk I/O.
@MainActor final class OnlineMusicPreviewSession {
    let item: AVPlayerItem
    private let asset: AVURLAsset
    private let loader: PreviewStreamLoader
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var cancelled = false

    var metrics: MusicPreviewStreamMetrics { loader.metrics }

    init(track: OnlineMusicTrack, configuration: URLSessionConfiguration = .ephemeral, useMemoryCache: Bool = true,
         initialBufferTimeout: TimeInterval = 15) throws {
        guard PreviewStreamLoader.isHTTPS(track.audioURL), PreviewStreamLoader.isHTTPS(track.sourceURL) else { throw OnlineMusicPreviewError.invalidURL }
        let ext = track.audioURL.pathExtension.lowercased()
        guard ext.isEmpty || ext == "mp3" else { throw OnlineMusicPreviewError.unsupportedFormat }
        let cacheKey = "\(track.id)|\(track.audioURL.absoluteString)|\(track.sourceURL.absoluteString)"
        let cached = useMemoryCache ? PreviewStreamCache.shared.value(for: cacheKey) : nil
        loader = PreviewStreamLoader(track: track, configuration: configuration, cacheKey: useMemoryCache ? cacheKey : nil,
                                     cached: cached, initialBufferTimeout: max(0.1, min(initialBufferTimeout, 15)))
        let url = URL(string: "yingshu-preview://\(UUID().uuidString.lowercased())/preview.mp3")!
        asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.5
        item.forwardPlaybackEndTime = CMTime(seconds: OnlineMusicPreview.targetDuration, preferredTimescale: 600)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                if status == .readyToPlay { self.loader.markPlayable() }
                else if status == .failed { self.loader.notePlaybackFailure(); self.cancel() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        loader.cancel(preserveBufferedPreview: true)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    deinit {
        loader.cancel(preserveBufferedPreview: true)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

/// A deliberately small, process-only replay cache. It never survives quitting the application.
private struct PreviewCachedPrefix {
    var data: Data
    var contentLength: Int
    var complete: Bool
    var validator: PreviewResourceValidator?
}
private struct PreviewResourceValidator: Equatable {
    enum Kind { case etag, modified }
    var kind: Kind
    var value: String
    static func from(_ response: HTTPURLResponse) -> PreviewResourceValidator? {
        if let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
           etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.hasPrefix("W/") { return PreviewResourceValidator(kind: .etag, value: etag) }
        if let modified = response.value(forHTTPHeaderField: "Last-Modified"), !modified.isEmpty {
            return PreviewResourceValidator(kind: .modified, value: modified)
        }
        return nil
    }
}
private final class PreviewStreamCache: @unchecked Sendable {
    static let shared = PreviewStreamCache()
    private let lock = NSLock()
    private var entries: [String: (date: Date, prefix: PreviewCachedPrefix)] = [:]
    func value(for key: String) -> PreviewCachedPrefix? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], Date().timeIntervalSince(entry.date) < 600 else { entries.removeValue(forKey: key); return nil }
        return entry.prefix
    }
    func store(_ prefix: PreviewCachedPrefix, for key: String) {
        guard !prefix.data.isEmpty, prefix.data.count <= OnlineMusicPreview.maximumNetworkBytes,
              prefix.complete || prefix.validator != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if let current = entries[key], current.prefix.data.count > prefix.data.count { return }
        entries[key] = (Date(), prefix)
        while entries.count > 3 || entries.values.reduce(0, { $0 + $1.prefix.data.count }) > OnlineMusicPreview.maximumNetworkBytes * 3 {
            guard let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
    func remove(_ key: String) { lock.lock(); entries.removeValue(forKey: key); lock.unlock() }
}

private final class PreviewStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.yingshu.music-preview-stream", qos: .userInitiated)
    private let track: OnlineMusicTrack, configuration: URLSessionConfiguration, cacheKey: String?
    private let initialBufferTimeout: TimeInterval
    private let stateLock = NSLock()
    private var recorded = MusicPreviewStreamMetrics()
    private var activeTask: URLSessionDataTask?
    private var cancelled = false
    private var rejectedPlayback = false
    // Everything below is confined to queue (also used by URLSession's serial delegate queue).
    private var session: URLSession?
    private var started = false, headerReady = false, finished = false, cacheEligible = false
    private var prefix = Data(), contentLength = 0, redirects = 0, networkStart = 0
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var failure: Error?
    private var validator: PreviewResourceValidator?
    private var startedAt: TimeInterval?

    var metrics: MusicPreviewStreamMetrics { stateLock.lock(); defer { stateLock.unlock() }; return recorded }
    private var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }

    init(track: OnlineMusicTrack, configuration: URLSessionConfiguration, cacheKey: String?, cached: PreviewCachedPrefix?, initialBufferTimeout: TimeInterval) {
        self.track = track; self.configuration = configuration; self.cacheKey = cacheKey
        self.initialBufferTimeout = initialBufferTimeout
        if let cached {
            prefix = cached.data; contentLength = cached.contentLength; headerReady = true; cacheEligible = true
            validator = cached.validator
            finished = cached.complete; started = cached.complete
            recorded.fromMemoryCache = true; recorded.networkFinished = cached.complete
            if cached.complete { recorded.firstByteDelay = 0 }
        }
        super.init()
    }

    func cancel(preserveBufferedPreview: Bool) {
        stateLock.lock(); cancelled = true; recorded.isCancelled = true; let task = activeTask; activeTask = nil; stateLock.unlock()
        task?.cancel()
        queue.async { [self] in
            stateLock.lock(); let rejected = rejectedPlayback; stateLock.unlock()
            if preserveBufferedPreview, cacheEligible, !rejected, let cacheKey, !prefix.isEmpty {
                PreviewStreamCache.shared.store(PreviewCachedPrefix(data: prefix, contentLength: contentLength, complete: finished, validator: validator), for: cacheKey)
            }
            for request in requests { request.finishLoading(with: CancellationError()) }
            requests = []; prefix = Data()
            session?.invalidateAndCancel(); session = nil
        }
    }
    func markPlayable() {
        queue.async { [self] in
            guard !isCancelled, failure == nil else { return }
            cacheEligible = true
            if finished, let cacheKey { PreviewStreamCache.shared.store(PreviewCachedPrefix(data: prefix, contentLength: contentLength, complete: true, validator: validator), for: cacheKey) }
        }
    }
    func notePlaybackFailure() {
        stateLock.lock()
        rejectedPlayback = true
        if recorded.failureMessage == nil { recorded.failureMessage = OnlineMusicPreviewError.invalidAudio.localizedDescription }
        stateLock.unlock()
        if let cacheKey { PreviewStreamCache.shared.remove(cacheKey) }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !isCancelled else { loadingRequest.finishLoading(with: CancellationError()); return true }
        requests.append(loadingRequest)
        fulfillRequests()
        if !started && !requests.isEmpty { startNetwork() }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }

    private func startNetwork() {
        guard !started, !isCancelled else { return }
        started = true; startedAt = ProcessInfo.processInfo.systemUptime; networkStart = prefix.count
        queue.asyncAfter(deadline: .now() + initialBufferTimeout) { [weak self] in
            guard let self, !self.isCancelled, !self.cacheEligible, self.failure == nil else { return }
            self.fail(OnlineMusicPreviewError.bufferTimeout)
        }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1; delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        var request = URLRequest(url: track.audioURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("YingShu/1.0 (progressive licensed music preview)", forHTTPHeaderField: "User-Agent")
        request.setValue(track.sourceURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("audio/mpeg, audio/mp3, application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(networkStart)-\(OnlineMusicPreview.maximumNetworkBytes - 1)", forHTTPHeaderField: "Range")
        if networkStart > 0 {
            guard let validator else { invalidatePartialCache(); fail(OnlineMusicPreviewError.sourceChanged); return }
            request.setValue(validator.value, forHTTPHeaderField: "If-Range")
        }
        let task = session.dataTask(with: request)
        stateLock.lock()
        if cancelled { stateLock.unlock(); task.cancel(); session.invalidateAndCancel(); return }
        activeTask = task; stateLock.unlock(); task.resume()
    }

    private func fulfillRequests() {
        guard !isCancelled else { return }
        var remaining: [AVAssetResourceLoadingRequest] = []
        for request in requests {
            if request.isCancelled || request.isFinished { continue }
            if let failure { request.finishLoading(with: failure); continue }
            guard headerReady else { remaining.append(request); continue }
            if let info = request.contentInformationRequest {
                info.contentType = UTType.mp3.identifier
                info.contentLength = Int64(contentLength)
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else { request.finishLoading(); continue }
            let start = max(data.currentOffset, data.requestedOffset)
            guard start >= 0, start <= Int64(contentLength) else { request.finishLoading(with: OnlineMusicPreviewError.invalidResponse); continue }
            let end: Int64
            if data.requestsAllDataToEndOfResource { end = Int64(contentLength) }
            else { end = data.requestedOffset + min(Int64(contentLength) - data.requestedOffset, Int64(data.requestedLength)) }
            let available = min(Int64(prefix.count), end)
            if available > start { data.respond(with: prefix.subdata(in: Int(start)..<Int(available))) }
            if data.currentOffset >= end || (finished && data.currentOffset >= Int64(prefix.count)) { request.finishLoading() }
            else { remaining.append(request) }
        }
        requests = remaining
    }

    private func fail(_ error: Error) {
        guard failure == nil, !isCancelled else { return }
        failure = error
        stateLock.lock(); recorded.failureMessage = error.localizedDescription; let task = activeTask; activeTask = nil; stateLock.unlock()
        task?.cancel(); session?.invalidateAndCancel(); session = nil
        fulfillRequests()
    }
    private func completeNetwork() {
        guard !finished else { return }
        stateLock.lock()
        guard !cancelled else { stateLock.unlock(); return }
        finished = true; recorded.networkFinished = true; activeTask = nil; stateLock.unlock()
        if cacheEligible, let cacheKey { PreviewStreamCache.shared.store(PreviewCachedPrefix(data: prefix, contentLength: contentLength, complete: true, validator: validator), for: cacheKey) }
        session?.invalidateAndCancel(); session = nil
        fulfillRequests()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard !isCancelled, redirects <= 3, let url = request.url, Self.isHTTPS(url) else {
            completionHandler(nil); fail(OnlineMusicPreviewError.invalidURL); return
        }
        var redirected = request
        redirected.setValue(track.sourceURL.absoluteString, forHTTPHeaderField: "Referer")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirected.setValue("bytes=\(networkStart)-\(OnlineMusicPreview.maximumNetworkBytes - 1)", forHTTPHeaderField: "Range")
        if networkStart > 0, let validator { redirected.setValue(validator.value, forHTTPHeaderField: "If-Range") }
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, let url = response.url, Self.isHTTPS(url) else {
            completionHandler(.cancel); fail(OnlineMusicPreviewError.invalidResponse); return
        }
        guard http.statusCode == 206 else {
            completionHandler(.cancel)
            if networkStart > 0, http.statusCode == 200 || http.statusCode == 416 {
                invalidatePartialCache(); fail(OnlineMusicPreviewError.sourceChanged); return
            }
            fail(http.statusCode == 200 || http.statusCode == 416 ? OnlineMusicPreviewError.rangeUnavailable : (http.statusCode == 429 ? OnlineMusicPreviewError.rateLimited : OnlineMusicPreviewError.unavailable)); return
        }
        let receivedValidator = PreviewResourceValidator.from(http)
        if networkStart > 0, validator == nil || validator != receivedValidator {
            completionHandler(.cancel); invalidatePartialCache(); fail(OnlineMusicPreviewError.sourceChanged); return
        }
        let mime = (response.mimeType ?? "").lowercased()
        guard ["audio/mpeg", "audio/mp3", "audio/x-mp3", "application/octet-stream", "binary/octet-stream"].contains(mime) else {
            completionHandler(.cancel); fail(OnlineMusicPreviewError.unsupportedFormat); return
        }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity", let header = http.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.range(header), range.start == networkStart else {
            completionHandler(.cancel); fail(OnlineMusicPreviewError.invalidResponse); return
        }
        guard range.end < OnlineMusicPreview.maximumNetworkBytes else { completionHandler(.cancel); fail(OnlineMusicPreviewError.tooLarge); return }
        let length = range.end - range.start + 1
        guard response.expectedContentLength < 0 || response.expectedContentLength == length else {
            completionHandler(.cancel); fail(OnlineMusicPreviewError.invalidResponse); return
        }
        validator = receivedValidator; contentLength = range.end + 1; headerReady = true
        completionHandler(.allow); fulfillRequests()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, failure == nil, !finished else { return }
        guard headerReady, data.count <= contentLength - prefix.count, data.count <= OnlineMusicPreview.maximumNetworkBytes - prefix.count else {
            fail(OnlineMusicPreviewError.tooLarge); return
        }
        stateLock.lock()
        guard !cancelled else { stateLock.unlock(); return }
        prefix.append(data)
        recorded.receivedBytes += data.count
        if recorded.firstByteDelay == nil, let startedAt { recorded.firstByteDelay = ProcessInfo.processInfo.systemUptime - startedAt }
        stateLock.unlock()
        fulfillRequests()
        if prefix.count == contentLength { completeNetwork() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isCancelled, failure == nil, !finished else { return }
        if error != nil { fail(OnlineMusicPreviewError.unavailable) }
        else if headerReady && prefix.count == contentLength { completeNetwork() }
        else { fail(OnlineMusicPreviewError.invalidResponse) }
    }
    private static func range(_ value: String) -> (start: Int, end: Int)? {
        let expression = try! NSRegularExpression(pattern: "^bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)$", options: .caseInsensitive)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let startRange = Range(match.range(at: 1), in: value), let endRange = Range(match.range(at: 2), in: value), let totalRange = Range(match.range(at: 3), in: value),
              let start = Int(value[startRange]), let end = Int(value[endRange]), start >= 0, end >= start, end < Int.max else { return nil }
        let total = String(value[totalRange])
        guard total == "*" || Int(total).map({ $0 > end }) == true else { return nil }
        return (start, end)
    }
    private func invalidatePartialCache() {
        stateLock.lock(); rejectedPlayback = true; stateLock.unlock()
        if let cacheKey { PreviewStreamCache.shared.remove(cacheKey) }
    }
    static func isHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local") && !host.contains(":") &&
            host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
    }
}
