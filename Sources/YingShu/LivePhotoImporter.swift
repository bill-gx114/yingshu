import AVFoundation
import Foundation
import ImageIO
import Photos

struct ImportCandidate: Equatable {
    var url: URL
    var stillURL: URL? = nil
    var livePhotoAssetID: String? = nil
}

/// Groups only one still and one readable movie carrying the same embedded asset identifier.
/// Filenames are never evidence of a Live Photo relationship.
enum LivePhotoImporter {
    private struct Item {
        var url: URL
        var isPhoto: Bool
        var assetID: String?
    }

    static func prepare(urls: [URL]) async -> [ImportCandidate] {
        var items: [Item] = []
        for url in urls {
            guard !Task.isCancelled else { return urls.map { ImportCandidate(url: $0) } }
            if MediaEngine.importNotice(for: url) != nil {
                items.append(Item(url: url, isPhoto: false, assetID: nil)); continue
            }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil {
                items.append(Item(url: url, isPhoto: true, assetID: photoAssetID(source: source)))
            } else {
                items.append(Item(url: url, isPhoto: false, assetID: await movieAssetID(url: url)))
            }
        }
        var photoGroups: [String: [Int]] = [:], movieGroups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let id = item.assetID else { continue }
            if item.isPhoto { photoGroups[id, default: []].append(index) }
            else { movieGroups[id, default: []].append(index) }
        }
        var pairs: [Int: Int] = [:]
        var consumedMovies = Set<Int>()
        for (id, photos) in photoGroups where photos.count == 1 {
            guard let movies = movieGroups[id], movies.count == 1 else { continue }
            let photo = photos[0], movie = movies[0]
            // A match must also be a valid system Live Photo resource pair. A corrupt movie
            // or an identifier copied into an unrelated file must never consume the still.
            guard await systemValidates(stillURL: items[photo].url, movieURL: items[movie].url) else { continue }
            pairs[photo] = movie; consumedMovies.insert(movie)
        }
        var result: [ImportCandidate] = []
        for (index, item) in items.enumerated() {
            if consumedMovies.contains(index) { continue }
            if let movie = pairs[index] {
                result.append(ImportCandidate(url: items[movie].url, stillURL: item.url, livePhotoAssetID: item.assetID))
            } else {
                result.append(ImportCandidate(url: item.url, livePhotoAssetID: item.isPhoto ? item.assetID : nil))
            }
        }
        return result
    }

    private static func photoAssetID(source: CGImageSource) -> String? {
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let index = primary >= 0 && primary < CGImageSourceGetCount(source) ? primary : 0
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let identifier = maker["17"] as? String else { return nil }
        return canonicalID(identifier)
    }

    private static func movieAssetID(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable),
                  let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let range = try await track.load(.timeRange)
            let duration = range.duration.seconds
            guard duration.isFinite, duration > 0 else { return nil }
            let metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
            let matching = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataContentIdentifier)
            var identifiers = Set<String>()
            for item in matching {
                if let value = try await item.load(.stringValue), let id = canonicalID(value) { identifiers.insert(id) }
            }
            guard identifiers.count == 1, let identifier = identifiers.first else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 64, height: 64)
            let segments = try await track.load(.segments)
            let firstPicture = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target.start }.min() ?? range.start
            _ = try await generator.image(at: CMTimeAdd(firstPicture, CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)))
            return identifier
        } catch { return nil }
    }

    private static func canonicalID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Camera asset IDs are UUIDs; normalise their case without changing other opaque IDs.
        return UUID(uuidString: trimmed)?.uuidString ?? trimmed
    }

    static func systemValidates(stillURL: URL, movieURL: URL) async -> Bool {
        let state = LivePhotoValidation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                let request = PHLivePhoto.request(withResourceFileURLs: [stillURL, movieURL], placeholderImage: nil,
                    targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFit) { photo, info in
                    if (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue == true { return }
                    state.resolve(photo != nil && info[PHLivePhotoInfoErrorKey] == nil)
                }
                state.setRequest(request)
                // Missing or damaged external resources must not leave batch import waiting forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { state.resolve(false) }
            }
        } onCancel: { state.resolve(false) }
    }
}

private final class LivePhotoValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var request: PHLivePhotoRequestID?
    private var result: Bool?
    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func setRequest(_ request: PHLivePhotoRequestID) {
        lock.lock(); self.request = request; let finished = result != nil; lock.unlock()
        if finished { PHLivePhoto.cancelRequest(withRequestID: request) }
    }
    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation, request = request
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        if let request { PHLivePhoto.cancelRequest(withRequestID: request) }
    }
}
