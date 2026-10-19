import CoreTransferable
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoLibraryImportResult {
    var urls: [URL]
    var failures: [String]
    var directory: URL?
}

/// A narrow seam for generated-resource tests. Production creates sources only from picker selections.
struct PhotoLibraryImportSource: @unchecked Sendable {
    var label: String
    var write: @Sendable (URL, @escaping @Sendable (Double, String) -> Void) async throws -> [URL]
}

enum PhotoLibraryImporter {
    static func materialize(items: [PhotosPickerItem], progress: @escaping @Sendable (Double, String) -> Void) async throws -> PhotoLibraryImportResult {
        let sources = items.enumerated().map { index, item in
            PhotoLibraryImportSource(label: "相册中的第 \(index + 1) 项") { directory, update in
                try await write(item: item, to: directory, progress: update)
            }
        }
        return try await materialize(sources: sources, storageRoot: importedMediaDirectory(), progress: progress)
    }

    static func importedMediaDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("YingShu", isDirectory: true).appendingPathComponent("Imported Media", isDirectory: true)
    }

    static func materialize(sources: [PhotoLibraryImportSource], storageRoot: URL,
                            progress: @escaping @Sendable (Double, String) -> Void) async throws -> PhotoLibraryImportResult {
        guard !sources.isEmpty else { return PhotoLibraryImportResult(urls: [], failures: [], directory: nil) }
        try Task.checkCancellation()
        let reporter = LibraryProgress(progress)
        let batch = storageRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        var retainBatch = false
        defer { if !retainBatch { try? FileManager.default.removeItem(at: batch) } }
        var urls: [URL] = [], failures: [String] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let itemID = UUID().uuidString
            let staging = batch.appendingPathComponent(".\(itemID)", isDirectory: true)
            let committed = batch.appendingPathComponent(itemID, isDirectory: true)
            reporter.update(Double(index) / Double(sources.count), "正在准备 \(source.label)…")
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                let selected = try await source.write(staging) { value, message in
                    reporter.update((Double(index) + max(0, min(0.97, value))) / Double(sources.count), message)
                }
                try Task.checkCancellation()
                guard !selected.isEmpty else { throw StudioError.message("系统没有返回可读取的照片或视频。") }
                var relativeNames: [String] = []
                for url in selected {
                    let clean = url.standardizedFileURL.resolvingSymlinksInPath()
                    let parent = staging.standardizedFileURL.resolvingSymlinksInPath()
                    guard clean.deletingLastPathComponent() == parent else {
                        throw StudioError.message("相册传输没有生成独立的本地素材副本。")
                    }
                    let values = try clean.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                        throw StudioError.message("相册资源尚未完整写入本机。")
                    }
                    _ = try await MediaEngine.inspect(url: clean)
                    relativeNames.append(clean.lastPathComponent)
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: committed)
                urls.append(contentsOf: relativeNames.map { committed.appendingPathComponent($0) })
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: staging)
                failures.append("\(source.label)：\(error.localizedDescription)")
            }
            reporter.update(Double(index + 1) / Double(sources.count), "已处理 \(index + 1) / \(sources.count) 项")
        }
        try Task.checkCancellation()
        retainBatch = !urls.isEmpty
        reporter.update(1, urls.isEmpty ? "没有导入新素材" : "相册素材已保存到本机")
        return PhotoLibraryImportResult(urls: urls, failures: failures, directory: retainBatch ? batch : nil)
    }

    private static func write(item: PhotosPickerItem, to directory: URL,
                              progress: @escaping @Sendable (Double, String) -> Void) async throws -> [URL] {
        let advertisesLivePhoto = item.supportedContentTypes.contains { $0.conforms(to: .livePhoto) }
        var receivedLivePhoto = false
        do {
            if let livePhoto: PHLivePhoto = try await load(item, type: PHLivePhoto.self, progress: { value in
                progress(value * 0.25, "正在从相册取得完整实况照片；iCloud 原片可能需要下载…")
            }) {
                receivedLivePhoto = true
                return try await write(livePhoto: livePhoto, to: directory) { value, message in
                    progress(0.25 + value * 0.7, message)
                }
            }
            if advertisesLivePhoto { throw StudioError.message("系统未交付完整实况资源；本次未降级成静态照片，请保持联网后重新选择。") }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if advertisesLivePhoto || receivedLivePhoto {
                throw StudioError.message("无法保存完整实况照片：\(error.localizedDescription) 若原片在 iCloud，请保持联网后重试。")
            }
            // Unsupported PHLivePhoto transfer is normal for an ordinary image/movie.
        }
        progress(0.15, "正在从相册复制照片或视频；iCloud 原片可能需要下载…")
        guard let transferred: PickerMediaFile = try await load(item, type: PickerMediaFile.self, progress: { value in
            progress(0.15 + value * 0.6, "正在下载并复制选中的照片或视频…")
        }) else { throw StudioError.message("系统没有交付这项素材的图片或视频文件。") }
        defer { transferred.lease.remove() }
        try Task.checkCancellation()
        let output = uniqueDestination(originalFilename: transferred.lease.url.lastPathComponent, directory: directory)
        try copySelectedFile(from: transferred.lease.url, to: output)
        progress(0.95, "照片或视频已复制到本机")
        return [output]
    }

    /// Works with the resources of this selected PHLivePhoto only; never fetches a PHAsset or a library.
    static func write(livePhoto: PHLivePhoto, to directory: URL,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> [URL] {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        let originalPhotos = resources.filter { $0.type == .photo }
        let originalMovies = resources.filter { $0.type == .pairedVideo }
        let photos = originalPhotos.isEmpty ? resources.filter { $0.type == .fullSizePhoto } : originalPhotos
        let movies = originalMovies.isEmpty ? resources.filter { $0.type == .fullSizePairedVideo } : originalMovies
        guard photos.count == 1, movies.count == 1 else {
            throw StudioError.message("系统未交付一组完整且唯一的实况照片与动态视频；本次未降级成静态照片。")
        }
        var result: [URL] = []
        for (index, resource) in [photos[0], movies[0]].enumerated() {
            try Task.checkCancellation()
            let url = uniqueDestination(originalFilename: resource.originalFilename, directory: directory)
            try await writeResource(resource, to: url) { value in
                progress((Double(index) + value) / 2, "正在保存实况\(index == 0 ? "照片" : "动态视频")：\(url.lastPathComponent)…")
            }
            result.append(url)
        }
        try Task.checkCancellation()
        let candidates = await LivePhotoImporter.prepare(urls: result)
        guard candidates.count == 1, candidates[0].stillURL != nil else {
            throw StudioError.message("实况资源写入后未通过照片与视频配对验证，已跳过这一项。")
        }
        return result
    }

    private static func writeResource(_ resource: PHAssetResource, to url: URL,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let state = try PhotoResourceWrite(url: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.install(continuation)
                guard state.isPending else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value in if state.isPending { progress(value) } }
                // writeData has no cancellation token. requestData streams exactly the same
                // resource bytes to disk and supplies a cancellable request ID.
                let request = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { state.receive($0) }, completionHandler: { state.complete($0) })
                state.setRequest(request)
            }
        } onCancel: { state.cancel() }
    }

    private static func load<T: Transferable>(_ item: PhotosPickerItem, type: T.Type,
                                               progress: @escaping @Sendable (Double) -> Void) async throws -> T? {
        try Task.checkCancellation()
        let state = PickerTransferWait<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
                state.install(continuation)
                guard state.isPending else { return }
                let request = item.loadTransferable(type: type) { state.complete($0) }
                state.setProgress(request, update: progress)
            }
        } onCancel: { state.cancel() }
    }

    static func copySelectedFile(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw StudioError.message("系统没有交付普通素材文件。") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StudioError.message("无法创建本地素材副本，请检查磁盘空间。")
        }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: data)
        }
        try output.synchronize()
        var attributes: [FileAttributeKey: Any] = [:]
        if let date = values.creationDate { attributes[.creationDate] = date }
        if let date = values.contentModificationDate { attributes[.modificationDate] = date }
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: destination.path) }
        complete = true
    }

    private static func uniqueDestination(originalFilename: String, directory: URL) -> URL {
        let last = URL(fileURLWithPath: originalFilename).lastPathComponent
        let name = last.isEmpty || last == "." || last == ".." ? "相册素材" : last.replacingOccurrences(of: ":", with: "-")
        var output = directory.appendingPathComponent(name), suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            let value = URL(fileURLWithPath: name)
            let ext = value.pathExtension.isEmpty ? "" : "." + value.pathExtension
            output = directory.appendingPathComponent(value.deletingPathExtension().lastPathComponent + "-\(suffix)" + ext)
            suffix += 1
        }
        return output
    }
}

private final class PickerFileLease: @unchecked Sendable {
    let directory: URL
    let url: URL
    init(source: URL) throws {
        directory = try PhotoLibraryImporter.importedMediaDirectory().appendingPathComponent(".Transfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(source.lastPathComponent)
        do { try PhotoLibraryImporter.copySelectedFile(from: source, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

private struct PickerMediaFile: Transferable, @unchecked Sendable {
    let lease: PickerFileLease
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(lease: try PickerFileLease(source: received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            Self(lease: try PickerFileLease(source: received.file))
        }
    }
}

private final class LibraryProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private let callback: @Sendable (Double, String) -> Void
    init(_ callback: @escaping @Sendable (Double, String) -> Void) { self.callback = callback }
    func update(_ value: Double, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard value.isFinite else { return }
        last = max(last, min(1, max(0, value))); callback(last, message)
    }
}

private final class PickerTransferWait<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?
    private var result: Result<T?, Error>?
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    func install(_ value: CheckedContinuation<T?, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func setProgress(_ progress: Progress, update: @escaping @Sendable (Double) -> Void) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in update(value.fractionCompleted) }
        lock.lock(); self.progress = progress
        let finished = result != nil
        if !finished { self.observation = observation }
        lock.unlock()
        if finished { observation.invalidate(); progress.cancel() }
    }
    func complete(_ value: Result<T?, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let continuation = continuation, observation = observation
        self.continuation = nil; self.observation = nil
        lock.unlock(); observation?.invalidate(); continuation?.resume(with: value)
    }
    func cancel() {
        lock.lock(); let progress = progress; lock.unlock()
        complete(.failure(CancellationError())); progress?.cancel()
    }
}

final class PhotoResourceWrite: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let handle: FileHandle
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var request: PHAssetResourceDataRequestID?
    private var writeError: Error?
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw StudioError.message("无法创建本地实况资源文件。") }
        handle = try FileHandle(forWritingTo: url)
    }
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func setRequest(_ request: PHAssetResourceDataRequestID) {
        lock.lock(); self.request = request; let finished = result != nil || writeError != nil; lock.unlock()
        if finished { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
    func receive(_ data: Data) {
        lock.lock()
        guard result == nil, writeError == nil else { lock.unlock(); return }
        do { try handle.write(contentsOf: data) } catch { writeError = error }
        let failed = writeError != nil, request = request
        lock.unlock()
        if failed, let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
    func complete(_ error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        var failure = writeError ?? error
        do { try handle.synchronize(); try handle.close() } catch { if failure == nil { failure = error } }
        let value: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
        result = value; let continuation = continuation; self.continuation = nil
        lock.unlock()
        if failure != nil { try? FileManager.default.removeItem(at: url) }
        continuation?.resume(with: value)
    }
    func cancel() {
        lock.lock(); let request = request; lock.unlock()
        complete(CancellationError())
        if let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
}
