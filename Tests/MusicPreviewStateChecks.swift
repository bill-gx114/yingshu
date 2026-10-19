import AppKit
import AVFoundation
import Combine
import Foundation

private actor PreviewGate {
    private var waiters: [Int: CheckedContinuation<MusicPreviewClip, Error>] = [:]
    private(set) var count = 0
    func prepare(_ track: OnlineMusicTrack) async throws -> MusicPreviewClip {
        let index = count; count += 1
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }
    func finish(_ index: Int, _ clip: MusicPreviewClip) { waiters.removeValue(forKey: index)!.resume(returning: clip) }
    func fail(_ index: Int) { waiters.removeValue(forKey: index)!.resume(throwing: StudioError.message("测试来源无法试听")) }
}

@MainActor private final class PreviewSpeech: SpeechInput {
    let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var status = "离线测试"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    func start() async throws { isRecording = true; updates.send() }
    func stop() async -> String { isRecording = false; updates.send(); return "" }
    func cancel() { isRecording = false; updates.send() }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String { preconditionFailure("No speech service") }
}

@main struct MusicPreviewStateChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YingShuPreviewState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreviewGate(), speech = PreviewSpeech()
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false, speechInput: speech,
                             musicPreviewPreparer: { try await gate.prepare($0) })
        var clip = try await MediaEngine.inspect(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/demo-coast.png"))
        clip.duration = 4; model.clips = [clip]; model.automaticEditEnabled = false; model.musicVolume = 0
        model.captions = [Caption(clipID: clip.id, start: 0, duration: 4, text: "测试文字", style: .sticker)]
        model.seek(to: 1.25)
        let before = try JSONEncoder().encode(model.document)
        let a = track("a"), b = track("b")
        model.play(); model.toggleOnlineMusicPreview(a)
        try await wait { await gate.count == 1 }
        precondition(model.remotePreviewTrackID == a.id && model.isLoadingRemoteMusicPreview && !model.isPlaying)
        let pausedAt = model.currentTime
        model.toggleOnlineMusicPreview(a)
        let cancelled = try makePreview(in: root)
        await gate.finish(0, cancelled)
        try await wait { !FileManager.default.fileExists(atPath: cancelled.directory.path) }
        precondition(model.remotePreviewTrackID == nil && !model.isLoadingRemoteMusicPreview)

        model.toggleOnlineMusicPreview(a); try await wait { await gate.count == 2 }
        model.toggleOnlineMusicPreview(b); try await wait { await gate.count == 3 }
        let old = try makePreview(in: root), current = try makePreview(in: root)
        await gate.finish(1, old)
        try await wait { !FileManager.default.fileExists(atPath: old.directory.path) }
        precondition(model.remotePreviewTrackID == b.id && model.isLoadingRemoteMusicPreview)
        await gate.finish(2, current)
        try await wait { !model.isLoadingRemoteMusicPreview }
        precondition(model.remotePreviewTrackID == b.id && !model.isPreviewingMusic && !model.isPlaying)
        precondition(model.currentTime == pausedAt && model.downloadedMusic.isEmpty && model.musicID == "breeze")
        model.play()
        precondition(model.remotePreviewTrackID == nil && !FileManager.default.fileExists(atPath: current.directory.path))
        model.pause()
        print("PASS: cancel/retry, switching tracks, late completion cleanup, temporary playback and movie mutual exclusion")

        model.toggleOnlineMusicPreview(a); try await wait { await gate.count == 4 }
        model.toggleRecording()
        try await wait { speech.isRecording }
        let interrupted = try makePreview(in: root)
        await gate.finish(3, interrupted)
        try await wait { !FileManager.default.fileExists(atPath: interrupted.directory.path) }
        precondition(model.remotePreviewTrackID == nil && !model.isLoadingRemoteMusicPreview && speech.isRecording)
        await model.finishRecording(autoResume: false)
        model.toggleOnlineMusicPreview(a); try await wait { await gate.count == 5 }
        await gate.fail(4)
        try await wait { model.remotePreviewTrackID == nil }
        precondition(model.remoteMusicPreviewMessage.contains("测试来源") && model.errorMessage == nil)

        let project = root.appendingPathComponent("project.json")
        try before.write(to: project)
        model.toggleOnlineMusicPreview(a); try await wait { await gate.count == 6 }
        try model.applyDocument(from: project)
        let previousProject = try makePreview(in: root)
        await gate.finish(5, previousProject)
        try await wait { !FileManager.default.fileExists(atPath: previousProject.directory.path) }
        precondition(model.remotePreviewTrackID == nil && model.downloadedMusic.isEmpty && model.musicID == "breeze")
        let decodedBefore = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let decodedAfter = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.document)) as! NSDictionary
        precondition(decodedBefore == decodedAfter, "Audition must not modify the project")
        await model.prepareToTerminate()
        print("PASS: dictation interrupts preview, errors remain inline, project changes reject old callbacks; project unchanged")
    }
    static func track(_ id: String) -> OnlineMusicTrack {
        OnlineMusicTrack(id: id, name: "测试" + id, artist: "离线测试", audioURL: URL(string: "https://example.invalid/\(id).mp3")!,
                         sourceURL: URL(string: "https://example.invalid/\(id)")!, license: "CC0 1.0",
                         licenseURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!, duration: 60)
    }
    static func makePreview(in root: URL) throws -> MusicPreviewClip {
        let directory = root.appendingPathComponent("YingShuMusicPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("preview.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        memset(buffer.floatChannelData![0], 0, 32000 * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return MusicPreviewClip(url: url, directory: directory, duration: 2)
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out waiting for preview state")
    }
}
