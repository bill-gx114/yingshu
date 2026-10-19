import AppKit
import Foundation
import Photos
import PhotosUI
import SwiftUI

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw StudioError.message(message) }
}
private final class ProgressRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private var invalid = false
    func update(_ value: Double, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        invalid = invalid || !value.isFinite || value < last || value > 1 || message.isEmpty
        last = value
    }
    func verify() throws {
        lock.lock(); defer { lock.unlock() }
        try require(!invalid && last == 1, "Progress was invalid, regressed or did not finish")
    }
}
@main struct PhotoLibraryImportChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); Foundation.exit(1) }
    }
    @MainActor private static func run() async throws {
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtures = project.appendingPathComponent("Tests/fixtures/live-photo", isDirectory: true)
        let run = project.appendingPathComponent("Tests/output/photo-library-import", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = run.appendingPathComponent("picker-source", isDirectory: true)
        let storage = run.appendingPathComponent("owned-imports", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for filename in ["iphone-style-still.heic", "iphone-style-motion.mov", "ordinary.png", "same-name.mov"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(filename), to: input.appendingPathComponent(filename))
        }
        let ordinary = input.appendingPathComponent("ordinary.png")
        let video = input.appendingPathComponent("same-name.mov")
        let still = input.appendingPathComponent("iphone-style-still.heic")
        let motion = input.appendingPathComponent("iphone-style-motion.mov")
        let sourcePhotoBytes = try Data(contentsOf: still), sourceMovieBytes = try Data(contentsOf: motion)
        let sourceOrdinaryBytes = try Data(contentsOf: ordinary)
        let fileDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: fileDate, .modificationDate: fileDate], ofItemAtPath: ordinary.path)
        let livePhoto = try await loadLivePhoto(still: still, movie: motion)
        let resources = PHAssetResource.assetResources(for: livePhoto)
        try require(resources.contains { $0.type == .photo } && resources.contains { $0.type == .pairedVideo }, "Generated PHLivePhoto has no complete resource pair")
        let progress = ProgressRecord()
        let sources = [
            PhotoLibraryImportSource(label: "完整实况") { directory, update in
                try await PhotoLibraryImporter.write(livePhoto: livePhoto, to: directory, progress: update)
            },
            PhotoLibraryImportSource(label: "模拟中途失败") { directory, _ in
                try Data("unfinished".utf8).write(to: directory.appendingPathComponent("partial.mov"))
                throw StudioError.message("模拟网络中断")
            },
            PhotoLibraryImportSource(label: "普通照片") { directory, _ in
                let output = directory.appendingPathComponent("ordinary.png")
                try PhotoLibraryImporter.copySelectedFile(from: ordinary, to: output); return [output]
            },
            PhotoLibraryImportSource(label: "普通视频") { directory, _ in
                let output = directory.appendingPathComponent("same-name.mov")
                try PhotoLibraryImporter.copySelectedFile(from: video, to: output); return [output]
            }
        ]
        let result = try await PhotoLibraryImporter.materialize(sources: sources, storageRoot: storage) { progress.update($0, $1) }
        try progress.verify()
        try require(result.urls.count == 4 && result.failures.count == 1 && result.directory != nil, "Partial success lost complete resources")
        try require(result.failures[0].contains("模拟网络中断"), "Failure did not describe the actual error")
        try require(result.urls.allSatisfy { $0.path.hasPrefix(storage.path + "/") }, "Project references a provider temporary URL")
        let children = try FileManager.default.contentsOfDirectory(atPath: result.directory!.path)
        try require(children.count == 3 && children.allSatisfy { !$0.hasPrefix(".") }, "Failed/unfinished selection directory survived")
        let stillName = resources.first { $0.type == .photo }!.originalFilename
        let movieName = resources.first { $0.type == .pairedVideo }!.originalFilename
        guard let importedStill = result.urls.first(where: { $0.lastPathComponent == stillName }),
              let importedMovie = result.urls.first(where: { $0.lastPathComponent == movieName }),
              let importedOrdinary = result.urls.first(where: { $0.lastPathComponent == "ordinary.png" }) else {
            throw StudioError.message("System-provided original filenames were not preserved")
        }
        try require(try Data(contentsOf: importedStill) == sourcePhotoBytes, "Still original data changed")
        try require(try Data(contentsOf: importedMovie) == sourceMovieBytes, "Motion data was lost or transcoded")
        try require(try Data(contentsOf: importedOrdinary) == sourceOrdinaryBytes, "Ordinary image was altered")
        let copiedDate = try importedOrdinary.resourceValues(forKeys: [.creationDateKey]).creationDate
        try require(abs((copiedDate ?? .distantPast).timeIntervalSince(fileDate)) < 0.01, "Provider file date was discarded")
        let beforeInfo = try await MediaEngine.inspect(url: still), afterInfo = try await MediaEngine.inspect(url: importedStill)
        try require(beforeInfo.capturedAt == afterInfo.capturedAt, "Capture EXIF date changed")
        try FileManager.default.removeItem(at: input)
        let candidates = await LivePhotoImporter.prepare(urls: result.urls)
        try require(candidates.count == 3 && candidates.filter { $0.stillURL != nil }.count == 1, "Durable resources no longer form one moving Live Photo")
        for url in result.urls { _ = try await MediaEngine.inspect(url: url) }
        print("PASS: selected PHLivePhoto resources persisted byte-for-byte; one image+MOV pair survives source deletion")
        print("PASS: ordinary image/video copies retain filenames and source dates; half-failure cleans only failed item; progress monotonic")

        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: storage.path))
        let cancelSource = PhotoLibraryImportSource(label: "cancel") { directory, _ in
            try Data("partial".utf8).write(to: directory.appendingPathComponent("unfinished.mov"))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return []
        }
        let first = PhotoLibraryImportSource(label: "first completed") { directory, _ in
            let output = directory.appendingPathComponent("ordinary.png")
            try PhotoLibraryImporter.copySelectedFile(from: importedOrdinary, to: output); return [output]
        }
        let cancellation = Task {
            try await PhotoLibraryImporter.materialize(sources: [first, cancelSource], storageRoot: storage) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000); cancellation.cancel()
        do { _ = try await cancellation.value; throw StudioError.message("Cancelled batch unexpectedly completed") }
        catch is CancellationError { }
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: storage.path)) == existing, "Cancelled batch left completed or partial files")
        try require(try Data(contentsOf: importedOrdinary) == sourceOrdinaryBytes, "Cancellation damaged a previous batch")
        let failure = PhotoLibraryImportSource(label: "all fail") { directory, _ in
            try Data("bad".utf8).write(to: directory.appendingPathComponent("bad.mov"))
            throw StudioError.message("expected failure")
        }
        let allFailed = try await PhotoLibraryImporter.materialize(sources: [failure], storageRoot: storage) { _, _ in }
        try require(allFailed.urls.isEmpty && allFailed.directory == nil && allFailed.failures.count == 1, "All-failed batch advertised a persisted success")
        try require(Set(try FileManager.default.contentsOfDirectory(atPath: storage.path)) == existing, "All-failed batch leaked files")
        let streamed = run.appendingPathComponent("cancelled-resource.mov")
        let state = try PhotoResourceWrite(url: streamed)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.install(continuation); state.receive(Data("partial bytes".utf8)); state.cancel()
                state.receive(Data("must never resurrect output".utf8)); state.complete(nil)
            }
            throw StudioError.message("Resource cancellation returned success")
        } catch is CancellationError { }
        try require(!FileManager.default.fileExists(atPath: streamed.path), "Cancelled stream wrote data after cancellation")
        print("PASS: cancellation removes the whole uncommitted batch; late resource callbacks cannot recreate a cancelled file; previous imports preserved")
        print("ALL PHOTO LIBRARY IMPORT CHECKS PASSED: \(run.path)")
        print("NOTE: no user photo library was read or changed; picker transfer API compiled, resource extraction exercised using a generated PHLivePhoto")
    }
    private static func loadLivePhoto(still: URL, movie: URL) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [still, movie], placeholderImage: nil,
                targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFit) { photo, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue == true { return }
                if let photo { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: info[PHLivePhotoInfoErrorKey] as? Error ?? StudioError.message("Generated live photo was not accepted")) }
            }
        }
    }
}
