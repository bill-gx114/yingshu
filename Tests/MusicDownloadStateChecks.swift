import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Intentionally ignores cancellation until explicitly released. This exercises the
/// return-after-cancel race without a network request or a timing-dependent server.
private actor ControlledMusicDownloads {
    private var requested: [String] = []
    private var waiters: [Int: CheckedContinuation<URL, Never>] = [:]
    private var returned: Set<Int> = []

    var requestCount: Int { requested.count }
    func didReturn(_ request: Int) -> Bool { returned.contains(request) }
    func download(_ track: OnlineMusicTrack) async -> URL {
        let request = requested.count
        requested.append(track.id)
        let url = await withCheckedContinuation { waiters[request] = $0 }
        returned.insert(request)
        return url
    }
    func complete(_ request: Int, with url: URL) {
        guard let waiter = waiters.removeValue(forKey: request) else {
            preconditionFailure("Download request \(request) was not waiting")
        }
        waiter.resume(returning: url)
    }
}

/// Implements the app's real SpeechInput contract without creating an audio engine,
/// asking for permission, or calling a speech recognition service.
@MainActor private final class DownloadStateSpeech: SpeechInput {
    private let updates = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { updates.eraseToAnyPublisher() }
    var isRecording = false
    var transcript = ""
    var status = "离线测试语音"
    var audioLevel: Float = 0
    var authorizationGranted = true
    var segments: [SpeechSegment] = []
    var wordSegments: [SpeechSegment] = []
    var hasFinalTiming = true
    var lastIssue: String?
    var isRecognizingFile = false
    var onUnexpectedStop: ((String) -> Void)?
    var holdStart = false
    private(set) var starts = 0
    private(set) var stops = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<String, Never>?
    var startIsWaiting: Bool { startWaiter != nil }
    var stopIsWaiting: Bool { stopWaiter != nil }

    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        isRecording = true; transcript = ""; updates.send()
    }
    func allowStart() {
        let waiter = startWaiter; startWaiter = nil; waiter?.resume()
    }
    func stop() async -> String {
        stops += 1; isRecording = false; updates.send()
        return await withCheckedContinuation { stopWaiter = $0 }
    }
    func completeStop(_ text: String) {
        transcript = text
        wordSegments = text.isEmpty ? [] : [SpeechSegment(text: text, timestamp: 0, duration: 0.8)]
        segments = wordSegments; updates.send()
        let waiter = stopWaiter; stopWaiter = nil; waiter?.resume(returning: text)
    }
    func cancel() { isRecording = false; allowStart(); completeStop(""); updates.send() }
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String {
        preconditionFailure("This check must never invoke a speech-file service")
    }
}

@main struct MusicDownloadStateChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yingshu-music-download-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("generated-photo.png")
        let audio = directory.appendingPathComponent("generated-silence.wav")
        try makeImage(at: image); try makeSilentWave(at: audio)

        try await checkCancelThenRetry(audio: audio)
        try await checkLateReturnAfterNewProject(audio: audio)
        try await checkLateReturnAfterOpenProject(directory: directory, image: image, audio: audio)
        for phase in DictationPhase.allCases {
            try await checkDictationLock(phase, image: image, audio: audio)
        }
        print("ALL MUSIC DOWNLOAD STATE CHECKS PASSED; generated temporary media only, no network, microphone, or user projects")
    }

    @MainActor private static func makeModel(_ downloads: ControlledMusicDownloads, speech: DownloadStateSpeech) -> AppModel {
        let model = AppModel(restoreProject: false, autosaveEnabled: false, automaticMusicSearchEnabled: false,
                             speechInput: speech, musicDownloader: { await downloads.download($0) })
        model.automaticEditEnabled = false; model.orderMode = .manual
        return model
    }

    @MainActor private static func checkCancelThenRetry(audio: URL) async throws {
        let downloads = ControlledMusicDownloads(), speech = DownloadStateSpeech()
        let model = makeModel(downloads, speech: speech)
        let track = track("cancel-retry")
        let originalMusic = model.musicID
        model.downloadAndUseMusic(track)
        try await waitUntil("first download starts") { await downloads.requestCount == 1 }
        model.cancelMusicDownload()
        await downloads.complete(0, with: audio)
        try await waitUntil("canceled successful return clears busy state") { model.downloadingMusicID == nil }
        precondition(model.downloadedMusic.isEmpty && model.musicID == originalMusic)
        precondition(model.musicSearchMessage.contains("已取消"), "Cancel must provide a settled result, not a stuck downloading message")
        model.downloadAndUseMusic(track)
        try await waitUntil("same track can be downloaded again") { await downloads.requestCount == 2 }
        await downloads.complete(1, with: audio)
        try await waitUntil("retry commits") { model.downloadingMusicID == nil && model.downloadedMusic.count == 1 }
        precondition(model.downloadedMusic[0].id == track.id && model.musicID == "online:" + track.id)
        precondition(model.selectedMusicURL == audio && model.errorMessage == nil && speech.starts == 0)
        await model.prepareToTerminate()
        print("PASS canceled await returning success clears state, preserves selection, and permits same-track retry")
    }

    @MainActor private static func checkLateReturnAfterNewProject(audio: URL) async throws {
        let downloads = ControlledMusicDownloads(), speech = DownloadStateSpeech()
        let model = makeModel(downloads, speech: speech)
        let old = track("new-old"), current = track("new-current")
        // Keeping the old timeline empty avoids the real confirmation/recovery UI.
        model.title = "旧的空项目"
        model.downloadAndUseMusic(old)
        try await waitUntil("old new-project download starts") { await downloads.requestCount == 1 }
        model.newProject()
        precondition(model.clips.isEmpty && model.downloadingMusicID == nil)
        let document = try encodedDocument(model)
        model.downloadAndUseMusic(current)
        try await waitUntil("new project download starts") { await downloads.requestCount == 2 }
        let message = model.musicSearchMessage
        await downloads.complete(0, with: audio)
        try await drainReturned(0, downloads: downloads)
        let afterOldReturn = try encodedDocument(model)
        precondition(afterOldReturn == document, "Old download cannot mutate the new project")
        precondition(model.downloadingMusicID == current.id && model.musicSearchMessage == message,
                     "Old cancellation cleanup cannot clear a newer download's state")
        await downloads.complete(1, with: audio)
        try await waitUntil("new project download commits") { model.downloadingMusicID == nil && model.downloadedMusic.count == 1 }
        precondition(model.downloadedMusic.map(\.id) == [current.id] && model.musicID == "online:" + current.id)
        await model.prepareToTerminate()
        print("PASS new-project generation discards late success while preserving a newer in-flight download")
    }

    @MainActor private static func checkLateReturnAfterOpenProject(directory: URL, image: URL, audio: URL) async throws {
        let downloads = ControlledMusicDownloads(), speech = DownloadStateSpeech()
        let model = makeModel(downloads, speech: speech)
        let old = track("open-old"), current = track("open-current")
        model.downloadAndUseMusic(old)
        try await waitUntil("old open-project download starts") { await downloads.requestCount == 1 }
        let clip = clip(image)
        let caption = Caption(clipID: clip.id, start: 0.4, duration: 2.5, text: "新项目的感想", style: .note)
        let saved = DownloadedMusic(id: "already-saved", name: "项目原有音乐", artist: "测试作者", localURL: audio,
                                    sourceURL: URL(string: "https://example.invalid/existing")!, license: "CC BY 4.0",
                                    licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!, attribution: "项目自己的署名")
        let document = ProjectDocument(title: "生成的新项目", clips: [clip], captions: [caption], format: .portrait,
                                       musicID: "online:" + saved.id, customMusicURL: nil, musicVolume: 0.17,
                                       automaticEditEnabled: false, orderMode: .manual, downloadedMusic: [saved])
        let project = directory.appendingPathComponent("generated-project.yingshu.json")
        try JSONEncoder().encode(document).write(to: project, options: .atomic)
        try model.applyDocument(from: project)
        precondition(model.downloadingMusicID == nil && model.selectedMusicAttribution == saved.attribution)
        let opened = try encodedDocument(model)
        model.downloadAndUseMusic(current)
        try await waitUntil("opened project download starts") { await downloads.requestCount == 2 }
        let message = model.musicSearchMessage
        await downloads.complete(0, with: audio)
        try await drainReturned(0, downloads: downloads)
        let afterOldReturn = try encodedDocument(model)
        precondition(afterOldReturn == opened, "Late return cannot change opened clips, captions, music, or settings")
        precondition(model.downloadingMusicID == current.id && model.musicSearchMessage == message)
        await downloads.complete(1, with: audio)
        try await waitUntil("opened project download commits") { model.downloadingMusicID == nil && model.downloadedMusic.count == 2 }
        precondition(model.downloadedMusic.map(\.id) == [saved.id, current.id] && model.musicID == "online:" + current.id)
        precondition(model.clips == document.clips && model.captions == document.captions && model.format == .portrait)
        await model.prepareToTerminate()
        print("PASS opening a generated project discards old completion without clearing its own download or media")
    }

    private enum DictationPhase: String, CaseIterable { case preparing, recording, finishing }
    @MainActor private static func checkDictationLock(_ phase: DictationPhase, image: URL, audio: URL) async throws {
        let downloads = ControlledMusicDownloads(), speech = DownloadStateSpeech()
        speech.holdStart = phase == .preparing
        let model = makeModel(downloads, speech: speech)
        model.clips = [clip(image)]; model.selectedClipID = model.clips[0].id; model.currentTime = 1.25
        let originalClips = model.clips, originalMusic = model.musicID, originalMusicURL = model.selectedMusicURL
        let downloaded = track("dictation-" + phase.rawValue)
        model.downloadAndUseMusic(downloaded)
        try await waitUntil("dictation download starts") { await downloads.requestCount == 1 }
        model.toggleRecording()
        var finishing: Task<Void, Never>?
        if phase == .preparing {
            try await waitUntil("speech preparation lock") { speech.startIsWaiting && model.isTranscribing }
        } else {
            try await waitUntil("speech recording starts") { speech.isRecording && !model.isTranscribing }
            if phase == .finishing {
                finishing = Task { await model.finishRecording(autoResume: false) }
                try await waitUntil("speech finalization lock") { speech.stopIsWaiting && model.isTranscribing && !speech.isRecording }
            }
        }
        precondition(!model.canEditStructure, "The selected dictation phase must actually hold the structural lock")
        let pausedTime = model.currentTime
        await downloads.complete(0, with: audio)
        try await waitUntil("download registers during \(phase.rawValue)") { model.downloadingMusicID == nil && model.downloadedMusic.count == 1 }
        precondition(model.downloadedMusic[0].id == downloaded.id && model.downloadedMusic[0].localURL == audio)
        precondition(model.musicID == originalMusic && model.selectedMusicURL == originalMusicURL,
                     "A download completing during \(phase.rawValue) must not replace the current music")
        precondition(model.clips == originalClips && model.captions.isEmpty && model.currentTime == pausedTime)
        precondition(!model.isPlaying && model.player.rate == 0 && model.musicPlayer.rate == 0,
                     "A background completion must not resume playback or make sound")
        precondition(model.musicSearchMessage.contains("结束当前操作后可在配乐列表选择"))
        if phase == .preparing {
            precondition(model.isTranscribing && speech.startIsWaiting)
            speech.allowStart()
            try await waitUntil("prepared speech starts") { speech.isRecording && !model.isTranscribing }
        }
        if finishing == nil {
            precondition(speech.isRecording && !model.isTranscribing)
            finishing = Task { await model.finishRecording(autoResume: false) }
            try await waitUntil("speech stop waits") { speech.stopIsWaiting && model.isTranscribing }
        } else { precondition(model.isTranscribing && speech.stops == 1) }
        speech.completeStop("下载期间口述的感想。")
        await finishing?.value
        precondition(!speech.isRecording && !model.isTranscribing && model.canEditStructure && speech.starts == 1 && speech.stops == 1)
        precondition(model.captions.count == 1 && model.captions[0].clipID == originalClips[0].id && model.captions[0].text == speech.transcript)
        precondition(model.clips == originalClips && model.musicID == originalMusic,
                     "Finishing dictation must not perform a deferred automatic music switch")
        model.setMusicSelection("online:" + downloaded.id)
        precondition(model.musicID == "online:" + downloaded.id && model.selectedMusicURL == audio,
                     "After dictation, the downloaded track remains available for an explicit choice")
        await model.prepareToTerminate()
        print("PASS download during speech \(phase.rawValue) only adds offline track; selection, paused timeline, and one final caption are preserved")
    }

    private static func track(_ id: String) -> OnlineMusicTrack {
        OnlineMusicTrack(id: id, name: "生成测试曲 " + id, artist: "离线测试作者",
                         audioURL: URL(string: "https://example.invalid/" + id + ".wav")!,
                         sourceURL: URL(string: "https://example.invalid/" + id)!, license: "CC BY 4.0",
                         licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!, duration: 1)
    }
    private static func clip(_ image: URL) -> MediaClip {
        MediaClip(url: image, name: "生成测试照片", kind: .image, duration: 8, sourceDuration: 30, timingLocked: true)
    }
    @MainActor private static func encodedDocument(_ model: AppModel) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(model.document)
    }
    @MainActor private static func waitUntil(_ reason: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw StudioError.message("Music download state timed out: " + reason)
    }
    @MainActor private static func drainReturned(_ request: Int, downloads: ControlledMusicDownloads) async throws {
        try await waitUntil("controlled late request returns") { await downloads.didReturn(request) }
        // Let the MainActor continuation process the return before checking that the
        // newer project/download was untouched. No real transfer timing is involved.
        try await Task.sleep(nanoseconds: 30_000_000)
    }
    private static func makeImage(at url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError.message("Unable to generate test photo")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { throw StudioError.message("Unable to generate test pixels") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.message("Unable to write generated photo") }
    }
    private static func makeSilentWave(at url: URL) throws {
        let sampleRate: UInt32 = 8_000, payloadSize = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36) + payloadSize); data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16)); data.append(contentsOf: "data".utf8); append(payloadSize)
        data.append(Data(repeating: 0, count: Int(payloadSize)))
        try data.write(to: url, options: .atomic)
    }
}
