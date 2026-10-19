import AppKit
import Foundation

@main struct MusicWorkflowChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Tests/output/music-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false)
        var clip = try await MediaEngine.inspect(url: root.appendingPathComponent("Resources/demo-coast.png"))
        clip.duration = 1
        let caption = Caption(clipID: clip.id, start: 0, duration: 1, text: "海边的风，慢一点。", style: .sticker)
        let audio = root.appendingPathComponent("Resources/breeze.wav")
        let credit = "《合成测试曲》— 测试作者\nhttps://example.org/music\nCC BY 4.0"
        let saved = DownloadedMusic(id: "fixture", name: "合成测试曲", artist: "测试作者", localURL: audio,
                                    sourceURL: URL(string: "https://example.org/music")!, license: "CC BY 4.0",
                                    licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!, attribution: credit)
        let doc = ProjectDocument(title: "合成工作流", clips: [clip], captions: [caption], format: .landscape,
                                  musicID: "online:fixture", customMusicURL: nil, musicVolume: 0.2,
                                  automaticEditEnabled: false, orderMode: .manual, downloadedMusic: [saved])
        let project = output.appendingPathComponent("fixture.json")
        try JSONEncoder().encode(doc).write(to: project)
        try model.applyDocument(from: project)
        precondition(model.selectedMusicURL == audio && model.selectedMusicAttribution == credit)
        precondition(model.musicTracks.last?.id == "online:fixture")
        model.setMusicSelection("breeze")
        model.undoEdit()
        precondition(model.selectedMusicURL == audio && model.document.downloadedMusic == [saved])
        model.searchOnlineMusic(query: " ")
        precondition(!model.isSearchingMusic && model.onlineMusicResults.isEmpty)
        precondition(MusicRecommendationEngine.searchQuery(for: "轻柔钢琴") == "piano")
        precondition(MusicRecommendationEngine.searchQuery(for: "想要轻快的钢琴") == "piano upbeat")
        precondition(MusicRecommendationEngine.searchQuery(for: "unlisted artist") == "unlisted artist")
        let nature = MusicRecommendationEngine.recommendation(scores: ["forest": 0.8], captions: "", averageDuration: 4, analyzed: 1)
        let city = MusicRecommendationEngine.recommendation(scores: ["city": 0.8], captions: "", averageDuration: 4, analyzed: 1)
        precondition(nature.queries.first != city.queries.first)
        let recommendation = try await MusicRecommendationEngine.analyze(clips: [clip], captions: [caption])
        precondition(recommendation.queries.count == 3 && !recommendation.summary.isEmpty)
        print("PASS: local Vision recommendation, query mapping, offline track persistence and undo")

        model.automaticEditEnabled = true
        let originalClips = model.clips, originalWords = model.captions
        model.startCaptionImageExport(to: output)
        try await waitForExport(model)
        guard let imageDirectory = model.lastExportURL else { preconditionFailure("Missing image output") }
        precondition(imageDirectory.hasDirectoryPath && model.exportKindLabel == "带字图片")
        precondition(model.clips == originalClips && model.captions == originalWords, "Image export must preserve timing")
        let images = try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
        precondition(images.count == 1)
        model.automaticEditEnabled = false
        let video = output.appendingPathComponent("licensed.mp4")
        model.startExport(to: video)
        // Video preparation begins in a Task; wait for it to acquire the export state first.
        for _ in 0..<100 where !model.isExporting && model.lastExportURL != video { try await Task.sleep(nanoseconds: 20_000_000) }
        try await waitForExport(model)
        precondition(model.lastExportURL == video && model.errorMessage == nil, model.errorMessage ?? model.status)
        let attribution = try String(contentsOf: video.deletingPathExtension().appendingPathExtension("music-credit.txt"))
        precondition(attribution.contains(credit) && attribution.contains("剪裁/循环"))
        model.setMusicSelection(nil); model.lastExportURL = nil
        model.startExport(to: video)
        for _ in 0..<100 where !model.isExporting && model.lastExportURL != video { try await Task.sleep(nanoseconds: 20_000_000) }
        try await waitForExport(model)
        precondition(model.lastExportURL == video)
        precondition(!FileManager.default.fileExists(atPath: video.deletingPathExtension().appendingPathExtension("music-credit.txt").path), "An overwritten video must not retain another track's attribution")
        print("PASS: image export keeps timeline; video exports accompanying attribution and removes stale credits on overwrite")

        var old = doc; old.downloadedMusic = nil; old.musicID = "breeze"
        try JSONEncoder().encode(old).write(to: project)
        try model.applyDocument(from: project)
        precondition(model.downloadedMusic.isEmpty && model.selectedMusicAttribution == nil)
        await model.prepareToTerminate()
        print("PASS: previous project format remains compatible; no network or microphone used")
    }
    @MainActor static func waitForExport(_ model: AppModel) async throws {
        for _ in 0..<600 {
            if !model.isExporting { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(!model.isExporting && model.exportProgress == 1, model.errorMessage ?? model.status)
    }
}
