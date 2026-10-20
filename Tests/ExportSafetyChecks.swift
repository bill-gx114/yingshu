import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw StudioError.message(message) }
}

private final class ExportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var success = false
    private var changedDestination = false
    func receive(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        count += 1; success = success || value == 1
    }
    func replaceOnce(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !changedDestination else { return }
        try action(); changedDestination = true
    }
    var isUntouched: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
    var reportedSuccess: Bool { lock.lock(); defer { lock.unlock() }; return success }
}

private final class CompletionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false
    func attach(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let invoke = requested
        if !invoke { self.action = action }
        lock.unlock(); if invoke { action() }
    }
    func request() {
        lock.lock(); requested = true; let action = action; self.action = nil
        lock.unlock(); action?()
    }
}

@main struct ExportSafetyChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }

    @MainActor private static func run() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("YingShu-export-safety-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let photoURL = root.appendingPathComponent("source.png")
        try createPhoto(at: photoURL)
        let original = try Data(contentsOf: photoURL)
        var photo = try await MediaEngine.inspect(url: photoURL); photo.duration = 0.5
        let target = root.appendingPathComponent("existing.mp4")
        let sentinel = Data("preserve previous finished export".utf8)
        try sentinel.write(to: target)
        let settings = ExportSettings(clips: [photo], captions: [], format: .square,
                                      musicURL: nil, musicVolume: 0.3, outputURL: target)

        for kind in ["same-path", "symlink", "hardlink"] {
            let destination: URL
            if kind == "same-path" { destination = photoURL }
            else {
                destination = root.appendingPathComponent("\(kind).mp4")
                if kind == "symlink" { try files.createSymbolicLink(at: destination, withDestinationURL: photoURL) }
                else { try files.linkItem(at: photoURL, to: destination) }
            }
            var attempt = settings; attempt.outputURL = destination
            try await reject(attempt, containing: "不能覆盖原始素材", beforeRendering: true)
            try require(try Data(contentsOf: destination) == original, "Rejected \(kind) export changed original")
        }
        var livePhoto = photo; livePhoto.kind = .video
        livePhoto.url = root.appendingPathComponent("paired-motion.mov")
        try Data("readable motion placeholder; protection must precede decoding".utf8).write(to: livePhoto.url)
        livePhoto.livePhotoStillURL = photoURL
        for destination in [photoURL, root.appendingPathComponent("hardlink.mp4")] {
            var attempt = settings; attempt.clips = [livePhoto]; attempt.outputURL = destination
            try await reject(attempt, containing: "不能覆盖原始素材", beforeRendering: true)
            try require(try Data(contentsOf: photoURL) == original, "Export overwrote a paired Live Photo still")
        }
        let directoryTarget = root.appendingPathComponent("folder-with-existing-files.mp4", isDirectory: true)
        try files.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        let retainedFile = directoryTarget.appendingPathComponent("keep.txt")
        try sentinel.write(to: retainedFile)
        var directorySettings = settings; directorySettings.outputURL = directoryTarget
        try await reject(directorySettings, containing: "导出位置是一个文件夹", beforeRendering: true)
        try require(try Data(contentsOf: retainedFile) == sentinel, "Export replaced an existing directory")
        let music = root.appendingPathComponent("selected.wav")
        try Data("readable local audio fixture".utf8).write(to: music)
        let musicLink = root.appendingPathComponent("music-link.mp4")
        try files.linkItem(at: music, to: musicLink)
        var linkedMusic = settings; linkedMusic.musicURL = music; linkedMusic.outputURL = musicLink
        try await reject(linkedMusic, containing: "不能覆盖配乐", beforeRendering: true)
        print("PASS: originals including Live Photo stills, music and existing folders protected across paths, symlinks and hard links")

        var missingMusic = settings; missingMusic.musicURL = root.appendingPathComponent("missing-music.wav")
        try await reject(missingMusic, containing: "missing-music.wav", beforeRendering: true)
        var remoteClip = photo; remoteClip.url = URL(string: "https://example.test\(photoURL.path)")!
        var remoteSettings = settings; remoteSettings.clips = [remoteClip]
        try await reject(remoteSettings, containing: "找不到素材", beforeRendering: true)

        let validCaption = Caption(clipID: photo.id, start: 0, duration: 0.5, text: "保留完整文字")
        var orphan = validCaption; orphan.clipID = UUID()
        var negative = validCaption; negative.start = -0.1
        var afterEnd = validCaption; afterEnd.start = photo.duration
        var notFinite = validCaption; notFinite.duration = .nan
        var zero = validCaption; zero.duration = 0
        var tooLong = validCaption; tooLong.text = String(repeating: "字", count: 4001)
        let invalidRows: [([Caption], String)] = [
            ([orphan], "找不到对应素材"), ([negative], "出现时间无效"),
            ([afterEnd], "起点已超出片段"), ([notFinite], "出现时间无效"),
            ([zero], "出现时间无效"), ([tooLong], "4000 字的导出上限"),
            ([validCaption, validCaption], "文字标识重复")
        ]
        for (rows, phrase) in invalidRows {
            var attempt = settings; attempt.captions = rows
            try await reject(attempt, containing: phrase, beforeRendering: true)
            let before = Set(try files.contentsOfDirectory(atPath: root.path))
            var message: String?
            do { _ = try await CaptionImageExporter.export(clips: [photo], captions: rows, format: .square, to: root) { _ in } }
            catch { message = error.localizedDescription }
            try require(message?.contains(phrase) == true, "PNG lost the specific caption error: \(message ?? "success")")
            if rows.count == 1 && rows.first != orphan {
                try require(message?.contains(photo.name) == true && message?.contains("请") == true,
                            "Caption error did not identify a repairable source")
            }
            if rows.first == tooLong {
                try require(message?.contains("拆分或精简") == true && message?.contains("原文字仍完整保留") == true,
                            "Long-caption error omitted the repair or implied text loss")
            }
            try require(Set(try files.contentsOfDirectory(atPath: root.path)) == before, "PNG preflight left staging files")
        }
        try require(try Data(contentsOf: target) == sentinel, "Preflight failure replaced an existing export")
        print("PASS: both exporters identify missing music and distinct caption length, timing and association repairs before rendering")

        let preCancelledProgress = ExportObservation()
        let preCancelled = Task {
            var invalid = settings; invalid.clips = []
            try await MediaEngine.export(settings: invalid) { preCancelledProgress.receive($0) }
        }
        preCancelled.cancel()
        do { try await preCancelled.value; throw StudioError.message("Already-cancelled export reported completion") }
        catch is CancellationError { }
        try require(preCancelledProgress.isUntouched, "Already-cancelled export reported progress")

        let changingTarget = root.appendingPathComponent("destination-changed-during-export.mp4")
        var changing = settings; changing.outputURL = changingTarget
        let observation = ExportObservation()
        var mutationError: String?
        do {
            try await MediaEngine.export(settings: changing) { value in
                observation.receive(value)
                if value >= 0.25 {
                    // Simulate another local process changing a save path during encoding.
                    try? observation.replaceOnce { try files.linkItem(at: photoURL, to: changingTarget) }
                }
            }
        } catch { mutationError = error.localizedDescription }
        try require(mutationError?.contains("现在指向原始素材或配乐") == true, "Changed destination was not rechecked: \(mutationError ?? "success")")
        try require(!observation.reportedSuccess, "Unsafe output reported success")
        try require(try Data(contentsOf: changingTarget) == original && Data(contentsOf: photoURL) == original, "Commit-time rejection changed an original")
        print("PASS: save path changed during encoding is rechecked; originals survive and 100 percent is withheld")

        for kind in ["missing", "corrupt"] {
            let videoURL = root.appendingPathComponent("\(kind)-video.mov")
            if kind == "corrupt" { try Data("not a movie".utf8).write(to: videoURL) }
            var video = photo; video.id = UUID(); video.kind = .video; video.name = "\(kind) 视频素材"; video.url = videoURL
            let row = Caption(clipID: video.id, start: 0, duration: 0.5, text: "不能漏掉")
            let before = Set(try files.contentsOfDirectory(atPath: root.path))
            let progress = ExportObservation()
            var message: String?
            do {
                _ = try await CaptionImageExporter.export(clips: [photo, video], captions: [validCaption, row], format: .square, to: root) { progress.receive($0) }
            } catch { message = error.localizedDescription }
            try require(message?.contains(video.name) == true && message?.contains(videoURL.lastPathComponent) == true && message?.contains("整批图片尚未保存") == true,
                        "Unhelpful PNG source error: \(message ?? "success")")
            try require(!progress.reportedSuccess && Set(try files.contentsOfDirectory(atPath: root.path)) == before, "Failed PNG batch leaked partial images")
        }
        let leftovers = try files.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".YingShu-") }
        try require(leftovers.isEmpty, "Failed MP4 export leaked a staged file")
        print("PASS: missing/corrupt video PNG errors identify source and preserve complete-batch atomicity")

        let corruptPhotoURL = root.appendingPathComponent("corrupt-photo.jpg")
        try Data("not a photograph".utf8).write(to: corruptPhotoURL)
        var corruptPhoto = photo; corruptPhoto.url = corruptPhotoURL
        let beforePhotoFailure = Set(try files.contentsOfDirectory(atPath: root.path))
        var photoFailure: String?
        do { _ = try await CaptionImageExporter.export(clips: [corruptPhoto], captions: [validCaption], format: .square, to: root) { _ in } }
        catch { photoFailure = error.localizedDescription }
        try require(photoFailure?.contains(corruptPhotoURL.lastPathComponent) == true && photoFailure?.contains("无法解码") == true && photoFailure?.contains("JPEG/HEIC") == true,
                    "A corrupt existing photo was misreported as missing: \(photoFailure ?? "success")")
        try require(Set(try files.contentsOfDirectory(atPath: root.path)) == beforePhotoFailure, "Corrupt photo left a partial image batch")

        // Once a batch has been atomically committed, a cancellation delivered by
        // its final success callback must not relabel the saved output as cancelled.
        let movieSignal = CompletionCancellation(), movieProgress = ExportObservation()
        let finishedMovie = Task {
            try await MediaEngine.export(settings: settings) { value in
                movieProgress.receive(value)
                if value == 1 { movieSignal.request() }
            }
        }
        movieSignal.attach { finishedMovie.cancel() }
        try await finishedMovie.value
        let movieDuration = try await AVURLAsset(url: target).load(.duration).seconds
        try require(movieProgress.reportedSuccess && movieDuration > 0 && Data(contentsOf: photoURL) == original,
                    "A late cancellation relabelled or damaged an already committed movie")
        var pairedMovie = try await MediaEngine.inspect(url: target); pairedMovie.livePhotoStillURL = photoURL
        let changedPosterTarget = root.appendingPathComponent("destination-changed-to-paired-photo.mp4")
        var pairedSettings = settings; pairedSettings.clips = [pairedMovie]; pairedSettings.outputURL = changedPosterTarget
        let pairedObservation = ExportObservation()
        var pairedError: String?
        do {
            try await MediaEngine.export(settings: pairedSettings) { value in
                pairedObservation.receive(value)
                if value >= 0.25 {
                    try? pairedObservation.replaceOnce { try files.linkItem(at: photoURL, to: changedPosterTarget) }
                }
            }
        } catch { pairedError = error.localizedDescription }
        try require(pairedError?.contains("现在指向原始素材或配乐") == true && !pairedObservation.reportedSuccess,
                    "A paired original photo was not protected at commit time")
        try require(try Data(contentsOf: changedPosterTarget) == original && Data(contentsOf: photoURL) == original,
                    "Commit-time rejection changed a paired original photo")
        let imageSignal = CompletionCancellation(), imageProgress = ExportObservation()
        let finishedImages = Task {
            try await CaptionImageExporter.export(clips: [photo], captions: [validCaption], format: .square, to: root) { value in
                imageProgress.receive(value)
                if value == 1 { imageSignal.request() }
            }
        }
        imageSignal.attach { finishedImages.cancel() }
        let committedImages = try await finishedImages.value
        try require(imageProgress.reportedSuccess && committedImages.count == 1 && files.fileExists(atPath: committedImages[0].path),
                    "A late cancellation lost a committed PNG batch")
        print("PASS: corrupt-photo diagnosis retains source and repair; pre-cancel and post-commit cancellation retain truthful outcomes")
        print("ALL EXPORT SAFETY CHECKS PASSED")
    }

    private static func reject(_ settings: ExportSettings, containing phrase: String, beforeRendering: Bool) async throws {
        let progress = ExportObservation()
        var message: String?
        do { try await MediaEngine.export(settings: settings) { progress.receive($0) } }
        catch { message = error.localizedDescription }
        try require(message?.contains(phrase) == true, "Expected rejection containing '\(phrase)', got \(message ?? "success")")
        try require(!progress.reportedSuccess && (!beforeRendering || progress.isUntouched), "Rejected export rendered or reported success")
    }

    private static func createPhoto(at url: URL) throws {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Could not create safety fixture")
    }
}
