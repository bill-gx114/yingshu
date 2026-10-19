import AppKit
import AVFoundation
import Foundation

/// Uses generated Live Photo resources only; never opens a user's project or microphone.
@main struct ImportWorkflowChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 3 else { throw StudioError.message("Expected generated still and movie resource paths") }
        let still = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let movie = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Tests/output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let upgrading = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        upgrading.automaticEditEnabled = false
        await upgrading.importURLs([still], arrange: false)
        precondition(upgrading.clips.count == 1 && upgrading.clips[0].kind == .image && upgrading.errorMessage == nil,
                     "Missing motion is a nonblocking static import, not a modal failure")
        precondition(upgrading.importSummary?.contains("静态") == true && upgrading.importDetails.count <= 3)
        let staticID = upgrading.clips[0].id
        upgrading.addWrittenCaption()
        let captionID = upgrading.captions[0].id
        await upgrading.importURLs([still, movie], arrange: false)
        precondition(upgrading.clips.count == 1 && upgrading.clips[0].id == staticID && upgrading.clips[0].kind == .video,
                     "Reselecting a full Live Photo repairs the existing still without duplication")
        precondition(upgrading.captions[0].id == captionID && upgrading.captions[0].clipID == staticID)
        precondition(upgrading.captions[0].start + upgrading.captions[0].duration <= upgrading.clips[0].duration + 0.001)
        upgrading.undoEdit()
        precondition(upgrading.clips.count == 1 && upgrading.clips[0].kind == .image && upgrading.captions[0].id == captionID,
                     "Undo restores static clip and its original caption")
        await upgrading.prepareToTerminate()
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        model.automaticEditEnabled = false; model.musicID = nil
        await model.importURLs([movie, still]) // Photos may be selected after their motion resource.
        precondition(model.errorMessage == nil, model.errorMessage ?? "")
        precondition(model.clips.count == 1, "A verified Live Photo is one logical clip")
        let clip = model.clips[0]
        precondition(clip.kind == .video && clip.url == movie && clip.livePhotoStillURL == still && clip.livePhotoAssetID != nil)
        precondition(model.thumbnails[clip.id] != nil && clip.importOrder == 0)
        model.seek(to: min(0.3, clip.duration * 0.2))
        model.addWrittenCaption()
        precondition(model.captions.count == 1 && model.captions[0].clipID == clip.id)
        let project = output.appendingPathComponent("live-photo-project.yingshu.json")
        try model.writeDocument(to: project)
        let reopened = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        try reopened.applyDocument(from: project)
        if reopened.clips != model.clips { print("Roundtrip clips differ: before=\(model.clips) after=\(reopened.clips)") }
        precondition(reopened.clips == model.clips && reopened.captions == model.captions)
        precondition(reopened.clips[0].livePhotoStillURL == still && reopened.orderMode == .chronological)
        let exported = output.appendingPathComponent("live-photo-workflow.mp4")
        try? FileManager.default.removeItem(at: exported)
        model.startExport(to: exported)
        for _ in 0..<400 {
            if model.lastExportURL == exported || model.errorMessage != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(model.lastExportURL == exported && !model.isExporting, model.errorMessage ?? "Workflow export did not finish")
        let asset = AVURLAsset(url: exported)
        let duration = try await asset.load(.duration).seconds
        precondition(abs(duration - clip.duration) < 0.12)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(tracks.isEmpty, "Live Photo source audio must stay muted")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: CMTime(seconds: min(0.2, duration * 0.2), preferredTimescale: 600)).image
        let last = try await generator.image(at: CMTime(seconds: duration * 0.8, preferredTimescale: 600)).image
        let firstPixels = first.dataProvider!.data! as Data, lastPixels = last.dataProvider!.data! as Data
        precondition(firstPixels != lastPixels, "The exported Live Photo must contain different moving frames")
        model.removeClip(clip.id); precondition(model.clips.isEmpty && model.captions.isEmpty)
        model.undoEdit()
        precondition(model.clips.count == 1 && model.clips[0].livePhotoStillURL == still && model.captions.count == 1)
        precondition(FileManager.default.fileExists(atPath: still.path) && FileManager.default.fileExists(atPath: movie.path), "Removing a paired clip never deletes either resource")
        await model.prepareToTerminate(); await reopened.prepareToTerminate()
        print("PASS: verified paired import, one dynamic clip, caption binding, project roundtrip, moving MP4 export, source mute, removal and undo")
        print("Generated workflow output: \(exported.path)")
    }
}
