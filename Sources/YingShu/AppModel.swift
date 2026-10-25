import AppKit
import AVFoundation
import Combine
import Darwin
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CaptionCleanupFeedbackKind: Equatable {
    case information, retainedOriginal, failure
}

@MainActor
final class AppModel: ObservableObject {
    @Published var title = "我的旅行手记"
    @Published var clips: [MediaClip] = []
    @Published var captions: [Caption] = []
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var format: VideoFormat = .landscape
    @Published var selectedClipID: UUID?
    @Published var selectedCaptionID: UUID?
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var isBusy = false
    @Published var isExporting = false
    @Published var isTranscribing = false
    @Published var exportProgress = 0.0
    @Published var status = "导入照片和视频，开始一段自己的故事。"
    @Published var errorMessage: String?
    @Published var importSummary: String?
    @Published var importDetails: [String] = []
    @Published private(set) var isImportingPhotoLibrary = false
    @Published var editingCaptionID: UUID?
    @Published var captionEditDraft = "" {
        didSet {
            if captionEditDraft != oldValue,
               captionCleanupInput != nil || captionCleanupIssue != nil || captionCleanupSuggestion != nil || isCleaningCaption {
                invalidateCaptionCleanupForDraftChange()
            }
        }
    }
    @Published private(set) var isPreparingCaptionEdit = false
    @Published private(set) var captionEditIssue: String?
    @Published private(set) var isCleaningCaption = false
    @Published private(set) var captionCleanupSuggestion: String?
    @Published private(set) var captionCleanupIssue: String?
    @Published private(set) var captionCleanupFeedbackKind: CaptionCleanupFeedbackKind = .information
    @Published private(set) var captionCleanupOriginalText: String?
    @Published var speechMode: SpeechRecognitionMode = .localFirst
    @Published var speechVocabularyText = ""
    @Published private(set) var isPreparingEnhancedSpeechModel = false
    @Published var isShowingSpeechSettings = false
    @Published private(set) var companionProfile: CompanionProfile = .classic
    @Published var isShowingCompanionEditor = false
    @Published var captionStyle: CaptionStyle = .sticker
    @Published var musicID: String? = "breeze"
    @Published var customMusicURL: URL?
    @Published var musicVolume = 0.32
    @Published var musicSearchQuery = ""
    @Published private(set) var downloadedMusic: [DownloadedMusic] = []
    @Published private(set) var onlineMusicResults: [OnlineMusicTrack] = []
    @Published private(set) var isSearchingMusic = false
    @Published private(set) var downloadingMusicID: String?
    @Published private(set) var musicSearchMessage = "输入风格、乐器或曲名，搜索可下载的配乐。"
    @Published private(set) var musicRecommendationSummary = "导入素材后，会在本机分析画面并推荐配乐。"
    @Published private(set) var recommendedMusicQueries: [String] = []
    @Published private(set) var isAnalyzingMusic = false
    @Published private(set) var isPreviewingMusic = false
    @Published private(set) var remotePreviewTrackID: String?
    @Published private(set) var isLoadingRemoteMusicPreview = false
    @Published private(set) var remoteMusicPreviewMessage = ""
    @Published private(set) var exportKindLabel = "短片"
    @Published var lastExportURL: URL?
    @Published var projectURL: URL?
    @Published private(set) var recoverySaveState: RecoverySaveState = .idle
    @Published private(set) var hasUnsavedProjectChanges = false
    @Published private(set) var missingProjectAssets: [MissingProjectAsset] = []
    @Published var isShowingMissingAssets = false
    @Published private(set) var isRelinkingAssets = false
    @Published private(set) var assetRelinkIssue: String?
    @Published var isCheckingSpeech = false
    @Published var automaticEditEnabled = true
    @Published private(set) var isAutoEditing = false
    @Published private(set) var autoEditProgress = 0.0
    @Published private(set) var autoEditSummary = "导入后会按画面内容与所选音乐安排节奏。"
    @Published var orderMode: ClipOrderMode = .chronological
    @Published private(set) var isOrdering = false
    @Published private(set) var orderProgress = 0.0
    @Published private(set) var orderSummary = "默认按拍摄时间串起旅程，也可选择智能叙事。"
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    let speech: any SpeechInput
    let player = AVPlayer()
    let musicPlayer = AVPlayer()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var playerClipID: UUID?
    private var playerClipURL: URL?
    private var thumbnailRequests: [UUID: UUID] = [:]
    private var isSeekingVideo = false
    private var seekGeneration = UUID()
    private var recordAnchor: (clipID: UUID, offset: Double, global: Double)?
    private var liveCaptionID = UUID()
    private var recordWallStart: Double?
    private var recordingGeneration = UUID()
    private var recordingTask: Task<Void, Never>?
    private var localAIWarmupTask: Task<Void, Never>?
    private var recordingMoments: [PlaybackMoment] = []
    private var recordingStyle: CaptionStyle = .sticker
    private var recordingWasPlaying = false
    private var saveTask: Task<Void, Never>?
    private var forwarding: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var autoEditTask: Task<Bool, Never>?
    private var autoEditGeneration = UUID()
    private var plannedFingerprint: Data?
    private var orderingTask: Task<Bool, Never>?
    private var orderingGeneration = UUID()
    private var photoLibraryTask: Task<Void, Never>?
    private var captionEditingTask: Task<Void, Never>?
    private var captionCleanupTask: Task<Void, Never>?
    private var captionCleanupDeadline: Task<Void, Never>?
    private var captionCleanupGeneration = UUID()
    private var captionCleanupInput: String?
    private var cleanupAfterOpeningCaptionID: UUID?
    private var enhancedSpeechPreparationTask: Task<Void, Never>?
    private let captionCleaner: @Sendable (String, [String]) async throws -> String
    private let captionAIAvailability: () -> SpeechTextCleanupAvailability
    private let captionCleanupTimeout: TimeInterval
    private var resumeAfterCaptionEditing = false
    private var lastCommittedRecordingCaptionID: UUID?
    private var musicObserver: NSObjectProtocol?
    private let musicPreviewPlayer = AVPlayer()
    private var musicPreviewObserver: NSObjectProtocol?
    private var musicPreviewStatus: NSKeyValueObservation?
    private var musicPreviewControlStatus: NSKeyValueObservation?
    private var musicPreviewTask: Task<Void, Never>?
    private var musicPreviewGeneration = UUID()
    private var remotePreviewClip: MusicPreviewClip?
    private var remotePreviewStream: OnlineMusicPreviewSession?
    private var remotePreviewName = ""
    private var remotePreviewStartedAt = 0.0
    private var remotePreviewHasStarted = false
    private var remotePreviewStalledAt: Double?
    private var musicRecommendationTask: Task<Void, Never>?
    private var musicSearchTask: Task<Void, Never>?
    private var musicDownloadTask: Task<Void, Never>?
    private var musicRecommendationGeneration = UUID()
    private var musicSearchGeneration = UUID()
    private var musicProjectGeneration = UUID()
    private var automaticMusicQuery: String?
    private let automaticMusicSearchEnabled: Bool
    private let musicDownloader: @Sendable (OnlineMusicTrack) async throws -> URL
    private let musicPreviewPreparer: (@Sendable (OnlineMusicTrack) async throws -> MusicPreviewClip)?
    private let musicPreviewStreamFactory: @MainActor (OnlineMusicTrack) throws -> OnlineMusicPreviewSession
    private var keyboardMonitor: Any?
    private let autosaveEnabled: Bool
    private let recoveryFileURL: URL?
    private let profileDefaults: UserDefaults
    static let companionProfileDefaultsKey = "YingShu.companionProfile.default.v1"
    private var savedProjectSnapshot: ProjectDocument?
    private var emptyProjectSnapshot: ProjectDocument?
    private let terminationSpeechGracePeriod: TimeInterval
    private var isTerminating = false
    private var undoHistory: [ProjectDocument] = []
    private var redoHistory: [ProjectDocument] = []
    private var lastUndoKey: String?
    private var lastUndoTime = 0.0
    var totalDuration: Double { clips.totalDuration }
    var currentClip: MediaClip? { clips.location(at: currentTime)?.clip }
    var currentOffset: Double { clips.location(at: currentTime)?.offset ?? 0 }
    var selectedClip: MediaClip? { clips.first { $0.id == selectedClipID } ?? currentClip }
    var visibleCaptions: [Caption] {
        guard let location = clips.location(at: currentTime) else { return [] }
        var visible = captions.filter { $0.clipID == location.clip.id && location.offset >= $0.start && location.offset < $0.start + $0.duration }
        if speech.isRecording, !speech.transcript.isEmpty {
            let aligned = alignedRecordingCaptions().filter { $0.clipID == location.clip.id }
            let liveText: String
            if !aligned.isEmpty { liveText = aligned.map(\.text).joined(separator: "\n") }
            else if speech.wordSegments.isEmpty, recordAnchor?.clipID == location.clip.id { liveText = speech.transcript }
            else { return visible }
            var draft = Caption(id: liveCaptionID, clipID: location.clip.id, start: 0, duration: location.clip.duration, text: liveText, style: recordingStyle)
            let previous = visible.filter { $0.style == draft.style }.map(\.text)
            draft.text = (previous + [liveText]).joined(separator: "\n")
            visible.removeAll { $0.style == draft.style }
            visible.append(draft)
        }
        return visible
    }
    var currentClipCaptions: [Caption] {
        captions.filter { $0.clipID == (selectedClipID ?? currentClip?.id) }.sorted { $0.start < $1.start }
    }
    var resourceURL: URL {
        let appResources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: appResources.appendingPathComponent("breeze.wav").path) { return appResources }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    }
    var musicTracks: [MusicTrack] {
        [MusicTrack(id: "breeze", name: "沿途的风", detail: "轻柔琴音 · 自制配乐", url: resourceURL.appendingPathComponent("breeze.wav"), license: "CC0 1.0"),
         MusicTrack(id: "afternoon", name: "慢一点的午后", detail: "温暖弦音 · 自制配乐", url: resourceURL.appendingPathComponent("afternoon.wav"), license: "CC0 1.0")]
        + downloadedMusic.map { MusicTrack(id: "online:" + $0.id, name: $0.name, detail: $0.artist + " · 已下载", url: $0.localURL, license: $0.license) }
    }
    var selectedMusicURL: URL? {
        if musicID == "custom" { return customMusicURL }
        return musicTracks.first { $0.id == musicID }?.url
    }
    var selectedMusicAttribution: String? {
        downloadedMusic.first { "online:" + $0.id == musicID }?.attribution
    }
    var currentPreviewStreamMetrics: MusicPreviewStreamMetrics? { remotePreviewStream?.metrics }
    var currentPreviewPlaybackTime: Double? {
        guard remotePreviewTrackID != nil else { return nil }
        let seconds = musicPreviewPlayer.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }
    private var canEditSpeechSettings: Bool { !speech.isRecording && !isTranscribing && !isBusy && !isExporting && !isCheckingSpeech && !isAutoEditing && !isOrdering && editingCaptionID == nil && !isPreparingCaptionEdit && !isPreparingEnhancedSpeechModel && !isShowingCompanionEditor && !isTerminating }
    var canEditStructure: Bool { canEditSpeechSettings && !isShowingSpeechSettings && !isShowingMissingAssets && !isRelinkingAssets }
    var canOpenCaptionEditor: Bool { !isBusy && !isExporting && !isCheckingSpeech && !isAutoEditing && !isOrdering && editingCaptionID == nil && !isPreparingCaptionEdit && !isPreparingEnhancedSpeechModel && !isShowingSpeechSettings && !isShowingCompanionEditor && !isShowingMissingAssets && !isRelinkingAssets && !isTerminating && !(isTranscribing && recordWallStart == nil) }
    var canUseCaptionAI: Bool { captionAIAvailability().isAvailable }
    var captionCleanupAvailabilityMessage: String { captionAIAvailability().message }
    var enhancedSpeechAvailability: EnhancedSpeechModelAvailability { speech.enhancedModelAvailability }
    var enhancedSpeechDownloadProgress: Double? { speech.enhancedModelDownloadProgress }
    var localAIReady: Bool { LocalAIVoiceService.runtimeAvailability.isReady }
    var localAIStatusMessage: String { LocalAIVoiceService.runtimeAvailability.message }
    private var recommendedSpeechMode: SpeechRecognitionMode { localAIReady ? .localAI : .localFirst }
    var capturePhaseMessage: String {
        if isTranscribing || speech.isRecording { return speech.status }
        return "开始口述会暂停画面，结束后自动继续。"
    }
    var canCancelRecordingPreparation: Bool { isTranscribing && !isPreparingCaptionEdit && !isTerminating }
    var speechEngineSummary: String {
        switch speechMode {
        case .localAI:
            return DeepSeekSettings.cleanupEnabled
                ? "本机 AI 识别 → DeepSeek 整理文字；录音与画面不上传到 DeepSeek。"
                : "本地 AI · 语音识别与表达整理，音频与文字不外发。"
        case .systemService: return "Apple 系统识别 · 允许由 Apple 联网处理口述音频。"
        case .localFirst: return "系统本机 · \(enhancedSpeechAvailability.message)"
        }
    }
    private var speechVocabulary: [String] {
        SpeechRecognitionOptions(mode: speechMode, contextualStrings: speechVocabularyText.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r"))).contextualStrings
    }

    init(restoreProject: Bool = true, autosaveEnabled: Bool = true, automaticMusicSearchEnabled: Bool = true, speechInput: (any SpeechInput)? = nil,
         musicDownloader: (@Sendable (OnlineMusicTrack) async throws -> URL)? = nil,
         musicPreviewPreparer: (@Sendable (OnlineMusicTrack) async throws -> MusicPreviewClip)? = nil,
         musicPreviewStreamFactory: (@MainActor (OnlineMusicTrack) throws -> OnlineMusicPreviewSession)? = nil,
         captionCleaner: (@Sendable (String, [String]) async throws -> String)? = nil,
         captionAIAvailability: (() -> SpeechTextCleanupAvailability)? = nil,
         terminationSpeechGracePeriod: TimeInterval = 5, recoveryFileURL: URL? = nil, profileDefaults: UserDefaults = .standard,
         captionCleanupTimeout: TimeInterval = 20) {
        self.autosaveEnabled = autosaveEnabled
        self.recoveryFileURL = recoveryFileURL
        self.profileDefaults = profileDefaults
        self.recoverySaveState = autosaveEnabled ? .idle : .disabled
        self.terminationSpeechGracePeriod = max(0.05, min(10, terminationSpeechGracePeriod))
        self.automaticMusicSearchEnabled = automaticMusicSearchEnabled
        self.musicDownloader = musicDownloader ?? { try await OnlineMusicLibrary.download(track: $0) }
        self.musicPreviewPreparer = musicPreviewPreparer
        self.musicPreviewStreamFactory = musicPreviewStreamFactory ?? { try OnlineMusicPreview.stream(track: $0) }
        self.captionCleaner = captionCleaner ?? { text, terms in try await SpeechTextCleaner.clean(text, protectedTerms: terms) }
        self.captionAIAvailability = captionAIAvailability ?? { SpeechTextCleaner.availability }
        self.captionCleanupTimeout = captionCleanupTimeout.isFinite ? max(0.01, min(60, captionCleanupTimeout)) : 20
        self.speech = speechInput ?? SpeechInputFactory.make()
        companionProfile = Self.savedCompanionProfile(in: profileDefaults)
        if speechInput == nil, localAIReady { speechMode = .localAI }
        player.isMuted = true
        forwarding = speech.changes.sink { [weak self] _ in self?.objectWillChange.send() }
        speech.onUnexpectedStop = { [weak self] text in
            guard let self, let anchor = self.recordAnchor, !self.isTranscribing else { return }
            self.capturePlaybackMoment()
            self.pause()
            let count = self.saveRecordingText(text, anchor: anchor, endTime: self.currentTime)
            self.clearRecordingContext()
            self.status = count > 0 ? self.recordingCompletionStatus(resuming: !self.isTerminating) : self.speech.status
            if !self.isTerminating { self.play() }
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let window = NSApp.keyWindow
            return self.handleEditorKeyDown(event, firstResponder: window?.firstResponder,
                isModal: window?.attachedSheet != nil || window?.sheetParent != nil || NSApp.modalWindow != nil)
        }
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        emptyProjectSnapshot = document
        savedProjectSnapshot = document
        if restoreProject { restoreAutosave() }
        Task { [weak self] in await self?.speech.refreshEnhancedModelAvailability() }
        if restoreProject, speechInput == nil, speechMode == .localAI, localAIReady {
            localAIWarmupTask = Task { try? await LocalAIVoiceService.shared.warmUp() }
        }
        if automaticMusicSearchEnabled, !clips.isEmpty { refreshMusicRecommendations() }
    }

    /// Native controls keep their own activation, navigation and text editing keys.
    /// The monitor and regression checks use this same path without posting global events.
    func handleEditorKeyDown(_ event: NSEvent, firstResponder: NSResponder?, isModal: Bool = false) -> NSEvent? {
        guard !isModal, !event.isARepeat, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        if firstResponder is NSTextView || firstResponder is NSControl { return event }
        if let view = firstResponder as? NSView {
            var ancestor = view.superview
            while let current = ancestor {
                if current is NSControl || current is NSTextView { return event }
                ancestor = current.superview
            }
        }
        switch event.keyCode {
        case 15: toggleRecording(); return nil
        case 49: togglePlayback(); return nil
        case 123: seek(to: currentTime - 3); return nil
        case 124: seek(to: currentTime + 3); return nil
        case 51, 117:
            if let id = selectedClipID { removeClip(id) }
            return nil
        default: return event
        }
    }

    func importMedia() {
        guard canEditStructure else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "选择本地照片或视频文件。直接从相册选择实况照片，请使用主界面的‘从相册选择’。"
        if panel.runModal() == .OK { Task { await importURLs(panel.urls) } }
    }

    func clearImportSummary() { importSummary = nil; importDetails = [] }
    func importFromPhotoLibrary(items: [PhotosPickerItem]) {
        guard canEditStructure, !items.isEmpty else { return }
        pause(); clearImportSummary(); isBusy = true; isImportingPhotoLibrary = true
        status = "正在读取相册中的完整素材…"
        photoLibraryTask = Task { [self] in
            do {
                let result = try await PhotoLibraryImporter.materialize(items: items) { [weak self] _, message in
                    Task { @MainActor in guard let self, self.isImportingPhotoLibrary else { return }; self.status = message }
                }
                try Task.checkCancellation()
                isBusy = false; isImportingPhotoLibrary = false
                if !isTerminating { await importURLs(result.urls, importNotices: result.failures) }
            } catch {
                isBusy = false; isImportingPhotoLibrary = false
                status = Task.isCancelled ? "已取消相册导入。" : "相册素材未能读取，请重试。"
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            photoLibraryTask = nil
        }
    }
    func cancelPhotoLibraryImport() { photoLibraryTask?.cancel() }

    func importURLs(_ urls: [URL], arrange: Bool = true, importNotices: [String] = []) async {
        guard canEditStructure else { return }
        pause(); clearImportSummary(); isBusy = true
        var failures: [String] = []
        var notices = importNotices
        var staticLiveNames: [String] = []
        var added = 0, upgraded = 0
        status = "正在识别素材与实况照片的配对关系…"
        let candidates = await LivePhotoImporter.prepare(urls: urls)
        guard !isTerminating, !Task.isCancelled else { isBusy = false; return }
        let nextImportOrder = (clips.compactMap(\.importOrder).max() ?? (clips.count - 1)) + 1
        for (index, candidate) in candidates.enumerated() {
            if isTerminating || Task.isCancelled { break }
            let url = candidate.url
            status = "正在读取素材 \(index + 1) / \(candidates.count)…"
            if let notice = MediaEngine.importNotice(for: url) { failures.append("\(url.lastPathComponent)：\(notice)"); continue }
            do {
                var clip: MediaClip
                do { clip = try await MediaEngine.inspect(url: url) }
                catch {
                    guard let stillURL = candidate.stillURL else { throw error }
                    clip = try await MediaEngine.inspect(url: stillURL)
                    notices.append("\(stillURL.lastPathComponent) 的动态视频无法读取，已保留静态照片。")
                }
                guard !isTerminating, !Task.isCancelled else { break }
                if let stillURL = candidate.stillURL, clip.kind == .video {
                    clip.livePhotoStillURL = stillURL
                    clip.name = stillURL.deletingPathExtension().lastPathComponent
                    if let still = try? await MediaEngine.inspect(url: stillURL) {
                        clip.capturedAt = still.capturedAt ?? clip.capturedAt
                        clip.fileCreatedAt = still.fileCreatedAt ?? clip.fileCreatedAt
                    }
                }
                clip.livePhotoAssetID = candidate.livePhotoAssetID
                guard !isTerminating, !Task.isCancelled else { break }
                clip.importOrder = nextImportOrder + added
                if clip.kind == .image, clip.livePhotoAssetID != nil {
                    staticLiveNames.append(clip.name)
                }
                if added + upgraded == 0 { checkpointUndo() }
                let oldMatches = clips.indices.filter { clips[$0].kind == .image && clip.livePhotoStillURL != nil && clip.livePhotoAssetID != nil && clips[$0].livePhotoAssetID == clip.livePhotoAssetID }
                if oldMatches.count == 1, let oldIndex = oldMatches.first {
                    let old = clips[oldIndex]
                    clip.id = old.id; clip.importOrder = old.importOrder ?? oldIndex; clip.timingLocked = old.timingLocked
                    clip.duration = min(old.duration, clip.sourceDuration - clip.trimStart)
                    clips[oldIndex] = clip
                    for captionIndex in captions.indices where captions[captionIndex].clipID == clip.id {
                        let minimum = min(0.1, clip.duration)
                        captions[captionIndex].start = max(0, min(captions[captionIndex].start, clip.duration - minimum))
                        captions[captionIndex].duration = max(minimum, min(captions[captionIndex].duration, clip.duration - captions[captionIndex].start))
                    }
                    upgraded += 1
                    if !captions.filter({ $0.clipID == clip.id }).isEmpty, clip.duration < old.duration { notices.append("\(clip.name) 已补全动态，原有感想保留；动态片段较短，请检查阅读时间。") }
                } else { clips.append(clip); added += 1 }
                let thumbnail = await MediaEngine.thumbnail(for: clip)
                guard !isTerminating, !Task.isCancelled else { break }
                thumbnails[clip.id] = thumbnail
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        isBusy = false
        guard !isTerminating else { return }
        if selectedClipID == nil { selectedClipID = clips.first?.id }
        syncPlayer(force: true)
        var summaryParts: [String] = []
        if added > 0 { summaryParts.append("已加入 \(added) 段素材") }
        if upgraded > 0 { summaryParts.append("\(upgraded) 段实况已补全动态") }
        if !staticLiveNames.isEmpty { summaryParts.append("\(staticLiveNames.count) 张实况暂以静态展示") }
        if !failures.isEmpty { summaryParts.append("\(failures.count) 项未能读取") }
        if summaryParts.isEmpty { summaryParts.append("没有加入新素材") }
        if !staticLiveNames.isEmpty {
            notices.insert("部分文件只提供了静态照片。请用‘从相册选择’重新选择实况，或从文件同时导入原照片与配对 MOV。已导入的画面可以继续使用。", at: 0)
            notices.append("暂以静态展示：" + staticLiveNames.joined(separator: "、"))
        }
        importSummary = summaryParts.joined(separator: "，") + "。"
        importDetails = notices + failures
        status = importSummary ?? "导入完成。"
        changed()
        refreshMissingProjectAssets()
        if added + upgraded > 0, arrange, !isTerminating, !Task.isCancelled {
            if orderMode == .manual {
                if automaticEditEnabled { _ = beginAutomaticEdit(recordUndo: false) }
            } else { _ = await beginOrdering(mode: orderMode, arrangeAfter: true, recordUndo: false).value }
        }
        if added + upgraded > 0, automaticMusicSearchEnabled, !isTerminating, !Task.isCancelled { refreshMusicRecommendations() }
    }

    func loadDemo() {
        guard canEditStructure, clips.isEmpty else { return }
        let urls = ["demo-coast.png", "demo-hills.png", "demo-evening.png"].map { resourceURL.appendingPathComponent($0) }
        Task {
            await importURLs(urls, arrange: false)
            guard clips.count == 3 else { return }
            title = "海边散步的一天"
            let names = ["海边的午后", "山野里的风", "不想结束的傍晚"]
            for index in clips.indices { clips[index].name = names[index] }
            captions = [
                Caption(clipID: clips[0].id, start: 0, duration: 4, text: "那天下午什么也没做，\n却是整趟旅行最舒服的时候。", style: .sticker),
                Caption(clipID: clips[1].id, start: 0, duration: 4, text: "慢一点，才能听见山里的风。", style: .note),
                Caption(clipID: clips[2].id, start: 0, duration: 4, text: "想把这样的傍晚，多留一会儿。", style: .subtitle)
            ]
            selectedCaptionID = captions.first?.id
            status = "示例项目 · 点播放，看看三段画面里的感想。"
            changed()
            if automaticEditEnabled { arrangeAutomatically() }
        }
    }

    private static func savedCompanionProfile(in defaults: UserDefaults) -> CompanionProfile {
        guard let data = defaults.data(forKey: companionProfileDefaultsKey),
              let profile = try? JSONDecoder().decode(CompanionProfile.self, from: data) else { return .classic }
        return profile.normalized()
    }
    func beginCompanionEditing() {
        guard canEditStructure else { return }
        pause(); stopMusicPreview()
        isShowingCompanionEditor = true
    }
    func cancelCompanionEditing() {
        isShowingCompanionEditor = false
    }
    func finishCompanionEditing(_ profile: CompanionProfile, useAsDefault: Bool) {
        // This action closes its own sheet, so it cannot use canEditStructure,
        // whose modal guard intentionally protects the rest of the editor.
        guard isShowingCompanionEditor, !isTerminating else { return }
        let confirmed = profile.normalized()
        let didChange = confirmed != companionProfile
        if didChange { checkpointUndo(); companionProfile = confirmed }
        if useAsDefault, let data = try? JSONEncoder().encode(confirmed) {
            profileDefaults.set(data, forKey: Self.companionProfileDefaultsKey)
        }
        captionStyle = .companion
        isShowingCompanionEditor = false
        status = "\(confirmed.displayName)已准备好，下一句口述会使用小人气泡。"
        if didChange { changed() }
    }

    func selectClip(_ clip: MediaClip) { guard canEditStructure else { return }; selectedClipID = clip.id; seek(to: clips.startTime(of: clip.id)) }
    func seek(to seconds: Double) {
        guard canEditStructure else { return }
        stopMusicPreview()
        currentTime = max(0, min(totalDuration, seconds)); lastTick = ProcessInfo.processInfo.systemUptime
        syncPlayer(force: true)
        syncMusic()
    }
    func togglePlayback() { guard !speech.isRecording && !isTranscribing else { return }; if isPlaying { pause() } else { play() } }
    func play() {
        guard !clips.isEmpty, !speech.isRecording, !isBusy, !isExporting, !isTranscribing, !isCheckingSpeech, !isAutoEditing, !isOrdering, !isPreparingCaptionEdit, editingCaptionID == nil, !isPreparingEnhancedSpeechModel, !isShowingSpeechSettings, !isShowingCompanionEditor, !isShowingMissingAssets, !isRelinkingAssets, !isTerminating else { return }
        stopMusicPreview()
        if currentTime >= totalDuration { currentTime = 0; syncPlayer(force: true) }
        lastTick = ProcessInfo.processInfo.systemUptime; isPlaying = true
        syncPlayer(force: true)
        if !speech.isRecording { syncMusic(); musicPlayer.play() }
    }
    func pause() { isPlaying = false; player.pause(); musicPlayer.pause(); stopMusicPreview() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastTick; lastTick = now
        defer { capturePlaybackMoment(now: now) }
        updateRemotePreviewPlaybackStatus()
        guard isPlaying else { return }
        if let location = clips.location(at: currentTime), location.clip.kind == .video {
            guard !isSeekingVideo else { return }
            if player.currentItem?.status == .failed {
                pause(); errorMessage = "无法播放“\(location.clip.name)”，请检查原素材。"; return
            }
            guard player.currentItem?.status == .readyToPlay,
                  player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return }
            let offset = player.currentTime().seconds - location.clip.trimStart
            guard offset.isFinite else { return }
            let next = offset >= location.clip.duration - 1.0 / 60 ? location.clip.duration : max(0, offset)
            currentTime = min(totalDuration, clips.startTime(of: location.clip.id) + next)
        } else { currentTime = min(totalDuration, currentTime + delta) }
        syncPlayer()
        if currentTime >= totalDuration {
            pause()
            if speech.isRecording { Task { await finishRecording() } }
        }
    }
    private func syncPlayer(force: Bool = false) {
        guard let location = clips.location(at: currentTime) else {
            seekGeneration = UUID(); isSeekingVideo = false
            player.replaceCurrentItem(with: nil); playerClipID = nil; playerClipURL = nil; return
        }
        let sourceChanged = location.clip.id != playerClipID || location.clip.url != playerClipURL
        if sourceChanged || force {
            let generation = UUID(); seekGeneration = generation
            if location.clip.id != playerClipID { selectedClipID = location.clip.id }
            if location.clip.kind == .video {
                isSeekingVideo = true
                player.pause()
                if sourceChanged { player.replaceCurrentItem(with: AVPlayerItem(url: location.clip.url)) }
                player.seek(to: CMTime(seconds: location.clip.trimStart + location.offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.seekGeneration == generation else { return }
                        self.isSeekingVideo = false; self.lastTick = ProcessInfo.processInfo.systemUptime
                        if finished && self.isPlaying { self.player.play() }
                    }
                }
            } else { isSeekingVideo = false; player.replaceCurrentItem(with: nil) }
            playerClipID = location.clip.id
            playerClipURL = location.clip.url
        }
    }
    func musicChanged() {
        stopMusicPreview()
        syncMusic(replace: true); changed()
        if automaticEditEnabled, !clips.isEmpty { arrangeAutomatically() }
    }
    private func syncMusic(replace: Bool = false) {
        guard let url = selectedMusicURL, FileManager.default.fileExists(atPath: url.path) else { musicPlayer.pause(); musicPlayer.replaceCurrentItem(with: nil); return }
        if replace || (musicPlayer.currentItem?.asset as? AVURLAsset)?.url != url {
            musicPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            if let musicObserver { NotificationCenter.default.removeObserver(musicObserver) }
            musicObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: musicPlayer.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPlaying, !self.speech.isRecording else { return }
                    self.musicPlayer.seek(to: .zero); self.musicPlayer.play()
                }
            }
        }
        musicPlayer.volume = Float(musicVolume)
        let duration = musicPlayer.currentItem?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 { musicPlayer.seek(to: CMTime(seconds: currentTime.truncatingRemainder(dividingBy: duration), preferredTimescale: 600)) }
        if isPlaying && !speech.isRecording { musicPlayer.play() }
    }
    func chooseCustomMusic() {
        guard canEditStructure else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        panel.message = "选择本地音乐文件；请确认你拥有视频使用权。也可以在配乐区域搜索可下载的曲目。"
        if panel.runModal() == .OK, let url = panel.url { checkpointUndo(); customMusicURL = url; musicID = "custom"; musicChanged() }
    }

    func refreshMusicRecommendations() {
        guard !isTerminating, !clips.isEmpty else { return }
        musicRecommendationTask?.cancel()
        let generation = UUID(); musicRecommendationGeneration = generation
        let snapshot = clips, words = captions, originalQuery = musicSearchQuery
        isAnalyzingMusic = true
        musicRecommendationTask = Task { [weak self] in
            do {
                let recommendation = try await MusicRecommendationEngine.analyze(clips: snapshot, captions: words)
                guard let self, !Task.isCancelled, !self.isTerminating, self.musicRecommendationGeneration == generation else { return }
                self.musicRecommendationSummary = recommendation.summary
                self.recommendedMusicQueries = recommendation.queries
                self.isAnalyzingMusic = false; self.musicRecommendationTask = nil
                // A query typed while analysis runs always takes priority over an automatic suggestion.
                if self.automaticMusicSearchEnabled, self.musicSearchQuery == originalQuery,
                   (originalQuery.isEmpty || originalQuery == self.automaticMusicQuery), let first = recommendation.queries.first {
                    self.automaticMusicQuery = first; self.musicSearchQuery = first; self.searchOnlineMusic()
                }
            } catch {
                guard let self, self.musicRecommendationGeneration == generation else { return }
                self.isAnalyzingMusic = false; self.musicRecommendationTask = nil
                if !Task.isCancelled { self.musicRecommendationSummary = "画面分析暂未完成，可以输入关键词选配乐。" }
            }
        }
    }
    func searchOnlineMusic(query: String) { automaticMusicQuery = nil; musicSearchQuery = query; searchOnlineMusic() }
    func searchOnlineMusic() {
        guard !isTerminating else { return }
        stopOnlineMusicPreview()
        if automaticMusicQuery != musicSearchQuery { automaticMusicQuery = nil }
        let query = MusicRecommendationEngine.searchQuery(for: musicSearchQuery)
        musicSearchTask?.cancel()
        let generation = UUID(); musicSearchGeneration = generation
        guard !query.isEmpty, query.count <= 120 else {
            isSearchingMusic = false; onlineMusicResults = []; musicSearchTask = nil
            musicSearchMessage = "请输入 1–120 个字符的关键词。"; return
        }
        isSearchingMusic = true; onlineMusicResults = []; musicSearchMessage = "正在检索可用于视频的配乐…"
        musicSearchTask = Task { [weak self] in
            do {
                let tracks = try await OnlineMusicLibrary.search(query: query)
                guard let self, !Task.isCancelled, !self.isTerminating, self.musicSearchGeneration == generation else { return }
                self.onlineMusicResults = tracks
                self.musicSearchMessage = tracks.isEmpty ? "没有找到合适曲目，可换个风格或英文关键词。" : "找到 \(tracks.count) 首 · CC0 或 CC BY；CC BY 分享时需保留署名。"
                self.isSearchingMusic = false; self.musicSearchTask = nil
            } catch {
                guard let self, self.musicSearchGeneration == generation else { return }
                self.isSearchingMusic = false; self.musicSearchTask = nil
                self.musicSearchMessage = Task.isCancelled ? "已取消搜索。" : error.localizedDescription
            }
        }
    }
    func downloadAndUseMusic(_ track: OnlineMusicTrack) {
        guard canEditStructure, downloadingMusicID == nil, !isTerminating else { return }
        if let saved = downloadedMusic.first(where: { $0.id == track.id }), FileManager.default.isReadableFile(atPath: saved.localURL.path) {
            setMusicSelection("online:" + track.id); musicSearchMessage = "已使用已下载的配乐。"; return
        }
        let generation = musicProjectGeneration
        let downloader = musicDownloader
        downloadingMusicID = track.id; musicSearchMessage = "正在下载并核验音乐与许可…"
        musicDownloadTask = Task { [weak self] in
            do {
                let url = try await downloader(track)
                guard let self, !self.isTerminating, self.musicProjectGeneration == generation else { return }
                try Task.checkCancellation()
                let maySelect = self.canEditStructure
                if maySelect { self.checkpointUndo() }
                self.downloadedMusic.removeAll { $0.id == track.id }
                self.downloadedMusic.append(DownloadedMusic(id: track.id, name: track.name, artist: track.artist, localURL: url, sourceURL: track.sourceURL, license: track.license, licenseURL: track.licenseURL, attribution: track.attributionText))
                self.downloadingMusicID = nil; self.musicDownloadTask = nil
                if maySelect {
                    self.musicID = "online:" + track.id; self.musicChanged()
                    self.musicSearchMessage = "已下载并使用《\(track.name)》，可离线使用。"
                } else { self.changed(); self.musicSearchMessage = "已下载《\(track.name)》，结束当前操作后可在配乐列表选择。" }
            } catch {
                guard let self, self.musicProjectGeneration == generation else { return }
                self.downloadingMusicID = nil; self.musicDownloadTask = nil
                self.musicSearchMessage = Task.isCancelled ? "已取消下载，原配乐保留。" : error.localizedDescription
            }
        }
    }
    func cancelMusicDownload() { musicDownloadTask?.cancel() }
    func toggleMusicPreview() {
        if isPreviewingMusic { stopMusicPreview(); return }
        guard canEditStructure, let url = selectedMusicURL, FileManager.default.isReadableFile(atPath: url.path) else { return }
        pause()
        startPreviewPlayback(url: url, generation: musicPreviewGeneration, remote: false)
    }
    func toggleOnlineMusicPreview(_ track: OnlineMusicTrack) {
        if remotePreviewTrackID == track.id { stopOnlineMusicPreview(); return }
        guard canEditStructure, !isTerminating else { return }
        pause()
        let generation = musicPreviewGeneration
        remotePreviewTrackID = track.id; isLoadingRemoteMusicPreview = true
        remotePreviewName = track.name; remotePreviewStartedAt = ProcessInfo.processInfo.systemUptime
        remotePreviewHasStarted = false; remotePreviewStalledAt = nil
        remoteMusicPreviewMessage = "正在连接《\(track.name)》，可随时停止…"
        guard let prepare = musicPreviewPreparer else {
            do {
                let stream = try musicPreviewStreamFactory(track)
                remotePreviewStream = stream
                startPreviewPlayback(item: stream.item, generation: generation, remote: true)
            } catch {
                stopMusicPreview(); remoteMusicPreviewMessage = error.localizedDescription
            }
            return
        }
        musicPreviewTask = Task { [weak self] in
            do {
                let preview = try await prepare(track)
                guard let self, !self.isTerminating, self.musicPreviewGeneration == generation else {
                    OnlineMusicPreview.remove(preview); return
                }
                if Task.isCancelled { OnlineMusicPreview.remove(preview); throw CancellationError() }
                guard self.canEditStructure else {
                    OnlineMusicPreview.remove(preview); self.stopMusicPreview()
                    self.remoteMusicPreviewMessage = "当前操作结束后可重新试听。"; return
                }
                self.remotePreviewClip = preview; self.musicPreviewTask = nil
                self.startPreviewPlayback(url: preview.url, generation: generation, remote: true)
            } catch {
                guard let self, self.musicPreviewGeneration == generation else { return }
                let wasCancelled = Task.isCancelled || error is CancellationError
                self.stopMusicPreview()
                self.remoteMusicPreviewMessage = wasCancelled ? "已取消试听。" : error.localizedDescription
            }
        }
    }
    func stopOnlineMusicPreview() {
        guard remotePreviewTrackID != nil else { return }
        stopMusicPreview(); remoteMusicPreviewMessage = "试听已停止，当前配乐保留。"
    }
    private func startPreviewPlayback(url: URL, generation: UUID, remote: Bool) {
        startPreviewPlayback(item: AVPlayerItem(url: url), generation: generation, remote: remote)
    }
    private func startPreviewPlayback(item: AVPlayerItem, generation: UUID, remote: Bool) {
        musicPreviewPlayer.automaticallyWaitsToMinimizeStalling = !remote
        musicPreviewPlayer.replaceCurrentItem(with: item); musicPreviewPlayer.volume = Float(musicVolume)
        isPreviewingMusic = !remote
        musicPreviewStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                Task { @MainActor in
                    guard let self, self.musicPreviewGeneration == generation else { return }
                    let streamIssue = self.remotePreviewStream?.metrics.failureMessage
                    self.stopMusicPreview()
                    if remote { self.remoteMusicPreviewMessage = streamIssue ?? "试听无法播放，可重试或打开曲目来源查看。" }
                    else { self.musicSearchMessage = "无法试听这份音频，请重新选择或下载。" }
                }
            }
        }
        musicPreviewObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.musicPreviewGeneration == generation else { return }
                self.stopMusicPreview()
                if remote { self.remoteMusicPreviewMessage = "试听结束，喜欢的话可下载并使用。" }
            }
        }
        if remote {
            musicPreviewControlStatus = musicPreviewPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.musicPreviewGeneration == generation else { return }
                    self.updateRemotePreviewPlaybackStatus()
                }
            }
            musicPreviewPlayer.playImmediately(atRate: 1)
        } else { musicPreviewPlayer.play() }
    }
    private func updateRemotePreviewPlaybackStatus() {
        guard remotePreviewTrackID != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let issue = remotePreviewStream?.metrics.failureMessage {
            stopMusicPreview(); remoteMusicPreviewMessage = issue; return
        }
        let seconds = musicPreviewPlayer.currentTime().seconds
        if musicPreviewPlayer.timeControlStatus == .playing, seconds.isFinite, seconds > 0.03 {
            remotePreviewHasStarted = true; remotePreviewStalledAt = nil
            if isLoadingRemoteMusicPreview { isLoadingRemoteMusicPreview = false }
            let message = "正在试听《\(remotePreviewName)》· 最长20秒，当前配乐不变。"
            if remoteMusicPreviewMessage != message { remoteMusicPreviewMessage = message }
            return
        }
        if !remotePreviewHasStarted || musicPreviewPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if !isLoadingRemoteMusicPreview { isLoadingRemoteMusicPreview = true }
            if remotePreviewHasStarted, remotePreviewStalledAt == nil { remotePreviewStalledAt = now }
            let hasBytes = (remotePreviewStream?.metrics.receivedBytes ?? 0) > 0 || remotePreviewClip != nil
            let message = remotePreviewHasStarted ? "网络较慢，正在缓冲《\(remotePreviewName)》，可随时停止。"
                : (hasBytes ? "正在缓冲《\(remotePreviewName)》，收到足够声音后就开始播放…" : "正在连接《\(remotePreviewName)》，可随时停止…")
            if remoteMusicPreviewMessage != message { remoteMusicPreviewMessage = message }
            if (!remotePreviewHasStarted && now - remotePreviewStartedAt >= 15) || (remotePreviewStalledAt.map { now - $0 >= 15 } ?? false) {
                stopMusicPreview(); remoteMusicPreviewMessage = "音乐来源响应较慢，本次试听已停止。可重试、换一首或打开来源页。"
            }
        }
    }
    private func stopMusicPreview() {
        let hadRemotePreview = remotePreviewTrackID != nil
        musicPreviewGeneration = UUID(); musicPreviewTask?.cancel(); musicPreviewTask = nil
        musicPreviewPlayer.pause(); musicPreviewPlayer.replaceCurrentItem(with: nil); isPreviewingMusic = false
        musicPreviewControlStatus = nil
        remotePreviewStream?.cancel(); remotePreviewStream = nil
        remotePreviewTrackID = nil; isLoadingRemoteMusicPreview = false
        if let preview = remotePreviewClip { OnlineMusicPreview.remove(preview); remotePreviewClip = nil }
        musicPreviewStatus = nil
        remotePreviewName = ""; remotePreviewHasStarted = false; remotePreviewStalledAt = nil
        if let musicPreviewObserver { NotificationCenter.default.removeObserver(musicPreviewObserver) }
        musicPreviewObserver = nil
        if hadRemotePreview { remoteMusicPreviewMessage = "试听已停止，当前配乐保留。" }
    }
    private func cancelMusicWork() {
        musicProjectGeneration = UUID(); musicRecommendationGeneration = UUID(); musicSearchGeneration = UUID()
        thumbnailRequests = [:]
        musicRecommendationTask?.cancel(); musicSearchTask?.cancel(); musicDownloadTask?.cancel()
        musicRecommendationTask = nil; musicSearchTask = nil; musicDownloadTask = nil
        isAnalyzingMusic = false; isSearchingMusic = false; downloadingMusicID = nil
        onlineMusicResults = []; recommendedMusicQueries = []; musicSearchQuery = ""; automaticMusicQuery = nil
        musicSearchMessage = "输入风格、乐器或曲名，搜索可下载的配乐。"
        musicRecommendationSummary = "导入素材后，会在本机分析画面并推荐配乐。"
        stopMusicPreview()
        remoteMusicPreviewMessage = ""
    }

    func toggleRecording() {
        guard !isTranscribing else { return }
        if speech.isRecording { Task { await finishRecording() }; return }
        guard canEditStructure, !clips.isEmpty else { return }
        if currentTime >= totalDuration { seek(to: 0) }
        recordingWasPlaying = isPlaying
        recordingGeneration = UUID()
        pause(); isTranscribing = true
        let generation = recordingGeneration
        recordingTask = Task { await beginRecording(generation: generation) }
    }
    private func beginRecording(generation: UUID) async {
        guard recordingGeneration == generation else { return }
        guard isTranscribing, recordAnchor == nil, !isTerminating else { isTranscribing = false; return }
        guard let location = clips.location(at: currentTime) else { return }
        pause(); isTranscribing = true
        recordAnchor = (location.clip.id, location.offset, currentTime)
        lastCommittedRecordingCaptionID = nil
        liveCaptionID = UUID()
        recordingStyle = captionStyle
        recordingMoments = []
        do {
            configureSpeechInput()
            try await speech.start()
            guard recordingGeneration == generation else { return }
            guard !isTerminating else { speech.cancel(); isTranscribing = false; recordAnchor = nil; return }
            recordWallStart = ProcessInfo.processInfo.systemUptime
            capturePlaybackMoment()
            isTranscribing = false
            recordingTask = nil
            status = "画面已暂停 · 放心说完这一句，R 结束后自动继续播放。"
            pause()
        } catch {
            guard recordingGeneration == generation else { return }
            recordingTask = nil
            isTranscribing = false; clearRecordingContext()
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            if recordingWasPlaying && !isTerminating { play() }
        }
    }
    func finishRecording(autoResume: Bool = true) async {
        guard !isTranscribing, let anchor = recordAnchor else { return }
        isTranscribing = true
        let generation = recordingGeneration
        let endTime = currentTime
        capturePlaybackMoment()
        pause()
        let text = await speech.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard recordingGeneration == generation else { return }
        let count = saveRecordingText(text, anchor: anchor, endTime: endTime)
        clearRecordingContext(); isTranscribing = false
        let willResume = autoResume && !isPreparingCaptionEdit && !isTerminating
        if count > 0 {
            status = recordingCompletionStatus(resuming: willResume)
        } else { status = speech.lastIssue ?? "没有识别到文字，请重试或写一句。" }
        if willResume { play() }
    }
    private func recordingCompletionStatus(resuming: Bool) -> String {
        if let issue = speech.cleanupIssue { return "识别文字已保留；\(issue)" }
        if speech.cleanupApplied { return resuming ? "已识别并整理到当前画面，继续播放。可在感想卡还原原文。" : "已识别并整理，原文可还原。" }
        return speech.hasFinalResult
            ? (resuming ? "感想已放到当前画面，已继续播放。" : "感想已保留，可以修改文字。")
            : "临时文字已保留，请检查末尾和显示位置。\(speech.lastIssue ?? "")"
    }
    /// Cancels loading or final AI processing without allowing a late result into a new take.
    func cancelRecordingPreparation() {
        guard isTranscribing else { return }
        let resume = recordingWasPlaying
        recordingGeneration = UUID()
        recordingTask?.cancel(); recordingTask = nil
        speech.cancel(); isTranscribing = false; clearRecordingContext()
        status = "已取消本次口述处理，原有感想保留。"
        if resume, !isPreparingCaptionEdit, !isTerminating { play() }
    }
    private func capturePlaybackMoment(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard let start = recordWallStart, let location = clips.location(at: currentTime), recordAnchor != nil else { return }
        let elapsed = max(0, now - start)
        if let last = recordingMoments.last, elapsed <= last.audioTime { return }
        recordingMoments.append(PlaybackMoment(audioTime: elapsed, clipID: location.clip.id, offset: location.offset))
    }
    private func alignedRecordingCaptions() -> [Caption] {
        DictationAlignment.captions(words: speech.wordSegments.map { DictationWord(text: $0.text, timestamp: $0.timestamp, duration: $0.duration) }, moments: recordingMoments, clips: clips, style: recordingStyle)
    }
    @discardableResult
    private func saveRecordingText(_ text: String, anchor: (clipID: UUID, offset: Double, global: Double), endTime: Double) -> Int {
        guard !text.isEmpty else { return 0 }
        var additions = alignedRecordingCaptions()
        if additions.isEmpty, let clip = clips.first(where: { $0.id == anchor.clipID }) {
            var caption = makeCaption(clip: clip, offset: anchor.offset, spokenDuration: endTime - anchor.global, text: text)
            caption.style = recordingStyle; additions = [caption]
        }
        let singleUntimedCaption = additions.count == 1 && speech.wordSegments.isEmpty
        additions = additions.compactMap { value in
            var caption = value
            caption.originalTranscript = singleUntimedCaption ? (speech.originalTranscript ?? caption.text) : caption.text
            caption.text = SpeechTextCleaner.captionText(caption.text)
            return caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : caption
        }
        var last: Caption?
        if !additions.isEmpty { checkpointUndo() }
        for caption in additions {
            last = commitSpokenCaption(caption)
        }
        if let last {
            lastCommittedRecordingCaptionID = last.id
            selectedCaptionID = last.id
            if !isPlaying { selectedClipID = last.clipID }
            changed()
        }
        return Set(additions.map(\.clipID)).count
    }
    private func clearRecordingContext() { recordAnchor = nil; recordWallStart = nil; recordingMoments = [] }

    func beginCaptionEditing(_ id: UUID) {
        guard canOpenCaptionEditor, captions.contains(where: { $0.id == id }) else { return }
        prepareCaptionEditor(targetID: id, requiresNewRecording: false)
    }
    func beginCaptionEditing(id: UUID) { beginCaptionEditing(id) }
    func beginCaptionCleanup(_ id: UUID) {
        guard canOpenCaptionEditor, captions.contains(where: { $0.id == id }) else { return }
        cleanupAfterOpeningCaptionID = id
        beginCaptionEditing(id)
    }
    func beginLiveCaptionEditing() {
        guard canOpenCaptionEditor, recordAnchor != nil, speech.isRecording || isTranscribing else { return }
        prepareCaptionEditor(targetID: nil, requiresNewRecording: true)
    }
    private func prepareCaptionEditor(targetID: UUID?, requiresNewRecording: Bool) {
        let wasDictating = speech.isRecording || isTranscribing
        resumeAfterCaptionEditing = wasDictating ? recordingWasPlaying : isPlaying
        pause(); isPreparingCaptionEdit = true; captionEditIssue = nil
        if !wasDictating { showCaptionEditor(targetID); return }
        captionEditingTask = Task { [self] in
            if speech.isRecording { await finishRecording(autoResume: false) }
            else if isTranscribing {
                // An existing stop is already collecting the last words. Never stop twice.
                for _ in 0..<60 {
                    if !isTranscribing || Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            guard !Task.isCancelled, !isTerminating, !isTranscribing else {
                isPreparingCaptionEdit = false; captionEditingTask = nil; return
            }
            let id = requiresNewRecording ? lastCommittedRecordingCaptionID : targetID
            showCaptionEditor(id)
        }
    }
    private func showCaptionEditor(_ id: UUID?) {
        guard let id, let caption = captions.first(where: { $0.id == id }) else {
            cleanupAfterOpeningCaptionID = nil
            isPreparingCaptionEdit = false; captionEditingTask = nil
            status = "没有可编辑的新文字，可以重新口述或写一句。"
            if resumeAfterCaptionEditing { play() }
            return
        }
        selectedCaptionID = id; selectedClipID = caption.clipID
        cancelCaptionCleanup()
        captionCleanupOriginalText = nil
        editingCaptionID = id; captionEditDraft = caption.text
        isPreparingCaptionEdit = false; captionEditingTask = nil
        status = "修改这句话，完成后同步到画面。"
        if cleanupAfterOpeningCaptionID == id {
            cleanupAfterOpeningCaptionID = nil
            if canUseCaptionAI { requestCaptionCleanup() }
            else { setCaptionCleanupFeedback(captionCleanupAvailabilityMessage, kind: .failure) }
        }
    }
    func saveCaptionEditing() {
        guard !isPreparingCaptionEdit, let id = editingCaptionID,
              let index = captions.firstIndex(where: { $0.id == id }) else { return }
        guard !captionEditDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            captionEditIssue = "请输入文字；如需删除这句，可在感想面板使用删除。"; return
        }
        guard captionEditDraft.utf16.count <= 4000 else { captionEditIssue = "这句话太长，请缩短到 4000 字符以内。"; return }
        if captions[index].text != captionEditDraft {
            checkpointUndo(); captions[index].text = captionEditDraft
            // A direct correction accepts this placement; export must not move the words
            // or retime the film merely because a mistaken character was corrected.
            plannedFingerprint = arrangementFingerprint
            changed()
        }
        closeCaptionEditor()
        status = "文字已更新到画面。"
    }
    func cancelCaptionEditing() {
        guard !isPreparingCaptionEdit else { return }
        closeCaptionEditor(); status = "已保留原文字。"
    }
    private func closeCaptionEditor() {
        let resume = resumeAfterCaptionEditing
        cancelCaptionCleanup()
        captionCleanupOriginalText = nil
        cleanupAfterOpeningCaptionID = nil
        editingCaptionID = nil; captionEditDraft = ""; captionEditIssue = nil
        resumeAfterCaptionEditing = false
        if resume, !isTerminating { play() }
    }

    /// Generation and input snapshots also protect against a reused ID after caption merging.
    func requestCaptionCleanup() {
        guard let id = editingCaptionID, let caption = captions.first(where: { $0.id == id }), !isPreparingCaptionEdit else { return }
        cancelCaptionCleanup()
        let input = captionEditDraft
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.utf16.count <= 2000 else {
            setCaptionCleanupFeedback("请先填写文字；每次可整理最多 2000 字符。", kind: .information); return
        }
        guard canUseCaptionAI else { setCaptionCleanupFeedback(captionCleanupAvailabilityMessage, kind: .failure); return }
        let generation = UUID()
        captionCleanupGeneration = generation
        captionCleanupInput = input
        captionCleanupOriginalText = input
        isCleaningCaption = true
        let terms = speechVocabulary
        captionCleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let suggestion = SpeechTextCleaner.captionText(try await self.captionCleaner(input, terms))
                guard !Task.isCancelled, self.captionCleanupGeneration == generation,
                      self.editingCaptionID == id, self.captionEditDraft == input,
                      self.captions.first(where: { $0.id == id }) == caption else { return }
                self.isCleaningCaption = false
                self.captionCleanupDeadline?.cancel(); self.captionCleanupDeadline = nil
                self.captionCleanupTask = nil
                if suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.setCaptionCleanupFeedback("整理结果没有可显示的文字，已保留当前草稿。", kind: .retainedOriginal)
                } else if suggestion == input { self.setCaptionCleanupFeedback("AI 已检查，这句话无需修改，可以直接完成。", kind: .information) }
                else { self.captionCleanupSuggestion = suggestion }
            } catch {
                guard !Task.isCancelled, self.captionCleanupGeneration == generation else { return }
                self.isCleaningCaption = false
                self.captionCleanupDeadline?.cancel(); self.captionCleanupDeadline = nil
                self.captionCleanupTask = nil
                if let cleanupError = error as? SpeechTextCleanupError, case .rejected = cleanupError {
                    self.setCaptionCleanupFeedback("AI 已处理，但建议未通过内容保留检查，未采用。原文完整保留，可继续手动修改或重新整理。", kind: .retainedOriginal)
                } else {
                    self.setCaptionCleanupFeedback(error.localizedDescription, kind: .failure)
                }
            }
        }
        let timeout = captionCleanupTimeout
        captionCleanupDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            guard let self, self.captionCleanupGeneration == generation, self.isCleaningCaption else { return }
            self.cancelCaptionCleanup()
            self.setCaptionCleanupFeedback("整理用时较长，已停止。原句保留，可重试或使用基础整理。", kind: .failure)
        }
    }
    func cancelCaptionCleanup() {
        captionCleanupGeneration = UUID()
        captionCleanupTask?.cancel(); captionCleanupTask = nil
        captionCleanupDeadline?.cancel(); captionCleanupDeadline = nil
        isCleaningCaption = false; captionCleanupSuggestion = nil; captionCleanupIssue = nil
        captionCleanupFeedbackKind = .information
        captionCleanupInput = nil
    }
    private func invalidateCaptionCleanupForDraftChange() {
        let wasWaiting = isCleaningCaption || captionCleanupSuggestion != nil
        cancelCaptionCleanup()
        if wasWaiting { setCaptionCleanupFeedback("文字已修改，旧建议已取消。可按当前文字重新整理。", kind: .information) }
    }
    private func setCaptionCleanupFeedback(_ message: String, kind: CaptionCleanupFeedbackKind) {
        captionCleanupFeedbackKind = kind
        captionCleanupIssue = message
    }
    func adoptCaptionCleanupSuggestion() {
        guard let suggestion = captionCleanupSuggestion, captionCleanupInput == captionEditDraft else { return }
        let before = captionCleanupOriginalText
        cancelCaptionCleanup()
        captionEditDraft = suggestion
        captionCleanupOriginalText = before
        setCaptionCleanupFeedback("已采用 AI 建议；点击完成后更新画面。", kind: .information)
    }
    func restoreCaptionCleanupOriginal() {
        guard let original = captionCleanupOriginalText else { return }
        cancelCaptionCleanup(); captionEditDraft = original
    }
    func basicCleanCaptionDraft() {
        guard editingCaptionID != nil else { return }
        let input = captionEditDraft
        let cleaned = SpeechTextCleaner.captionText(input)
        cancelCaptionCleanup()
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setCaptionCleanupFeedback("没有可整理的正文，已保留当前草稿。", kind: .information); return
        }
        if cleaned == input { setCaptionCleanupFeedback("空白与标点已经整齐，基础整理不会猜改错字。", kind: .information); return }
        captionCleanupOriginalText = input
        captionEditDraft = cleaned
        setCaptionCleanupFeedback("已整理空白和标点；完成后才同步画面。", kind: .information)
    }

    private func configureSpeechInput() {
        // Explicit words are most useful. A short project title may also be a place/event.
        let context = speechVocabulary + (title.count >= 2 && title.count <= 30 ? [title] : [])
        speech.configure(options: SpeechRecognitionOptions(mode: speechMode, contextualStrings: context))
    }
    func updateSpeechMode(_ mode: SpeechRecognitionMode) {
        guard canEditSpeechSettings, speechMode != mode else { return }
        checkpointUndo(); speechMode = mode; changed()
    }
    func updateSpeechVocabulary(_ text: String) {
        guard canEditSpeechSettings else { return }
        let terms = SpeechRecognitionOptions(mode: speechMode, contextualStrings: text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r"))).contextualStrings
        let normalized = terms.joined(separator: "\n")
        guard speechVocabularyText != normalized else { return }
        checkpointUndo(key: "speech-vocabulary"); speechVocabularyText = normalized; changed()
    }
    func prepareEnhancedSpeechModel() {
        guard canEditSpeechSettings, enhancedSpeechAvailability.canPrepare else { return }
        pause(); stopMusicPreview(); isPreparingEnhancedSpeechModel = true
        status = "正在准备增强中文识别资源，可在语音设置中取消。"
        enhancedSpeechPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speech.prepareEnhancedModel()
                if !Task.isCancelled { self.status = "增强中文识别已就绪，下次口述将优先使用。" }
            } catch {
                if !Task.isCancelled { self.status = "增强中文识别未准备完成：\(error.localizedDescription)" }
            }
            self.isPreparingEnhancedSpeechModel = false
            self.enhancedSpeechPreparationTask = nil
        }
    }
    func cancelEnhancedSpeechPreparation() {
        guard isPreparingEnhancedSpeechModel || enhancedSpeechPreparationTask != nil else { return }
        enhancedSpeechPreparationTask?.cancel(); speech.cancelEnhancedModelPreparation()
        status = "已取消增强模型准备，仍可使用兼容识别。"
    }
    func runSpeechCheck() {
        guard canEditStructure else { return }
        pause()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        panel.message = "选择一段有人声的音频检查中文识别。不会启用麦克风，也不会更改项目。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isCheckingSpeech = true; status = "正在检查系统中文识别…"
        Task {
            do {
                configureSpeechInput()
                let result = try await speech.transcribeFile(url: url)
                isCheckingSpeech = false
                status = "中文语音识别检查完成。"
                let alert = NSAlert(); alert.messageText = result.isEmpty ? "没有识别出文字" : "中文识别可用"; alert.informativeText = result.isEmpty ? "识别服务已完成，这段音频未识别出文字。" : result
                alert.addButton(withTitle: "完成"); alert.runModal()
            } catch { isCheckingSpeech = false; status = "语音检查未完成。"; errorMessage = error.localizedDescription }
        }
    }
    func makeCaption(clip: MediaClip, offset: Double, spokenDuration: Double, text: String) -> Caption {
        let duration = min(clip.duration, max(2.5, spokenDuration))
        let start = max(0, min(offset - 0.35, clip.duration - duration))
        return Caption(clipID: clip.id, start: start, duration: duration, text: text, style: captionStyle)
    }
    @discardableResult
    func commitSpokenCaption(_ caption: Caption) -> Caption {
        var start = caption.start, end = caption.start + caption.duration
        var merged: [Caption] = []
        var changedRange = true
        while changedRange {
            let found = captions.filter { existing in
                existing.clipID == caption.clipID && existing.style == caption.style &&
                !merged.contains(where: { $0.id == existing.id }) && existing.start < end && existing.start + existing.duration > start
            }
            changedRange = !found.isEmpty
            for item in found { start = min(start, item.start); end = max(end, item.start + item.duration); merged.append(item) }
        }
        guard !merged.isEmpty else { captions.append(caption); return caption }
        // A later long sentence may move earlier on screen to remain readable.
        // Keep the actual dictation order rather than sorting by that adjusted display time.
        let ordered = merged + [caption]
        let combinedText = ordered.map(\.text).joined(separator: "\n")
        let combinedOriginal = ordered.contains(where: { $0.originalTranscript != nil })
            ? ordered.map { $0.originalTranscript ?? $0.text }.joined(separator: "\n") : nil
        // Repeated takes must not grow one card beyond the editor/export limit.
        // Keep each take intact as a separate card rather than truncating words.
        guard combinedText.utf16.count <= 4000, (combinedOriginal?.utf16.count ?? 0) <= 100_000 else {
            captions.append(caption); return caption
        }
        var result = caption
        result.id = merged[0].id; result.start = start; result.duration = end - start
        result.text = combinedText; result.originalTranscript = combinedOriginal
        let oldIDs = Set(merged.map(\.id))
        captions.removeAll { oldIDs.contains($0.id) }; captions.append(result)
        return result
    }
    func addWrittenCaption() {
        guard canEditStructure, let clip = selectedClip ?? currentClip else { return }
        checkpointUndo()
        pause()
        let caption = makeCaption(clip: clip, offset: clip.id == currentClip?.id ? currentOffset : 0, spokenDuration: 3, text: "写下这一刻的感想")
        captions.append(caption); selectedCaptionID = caption.id; selectedClipID = clip.id; changed()
    }
    func updateCaption(_ caption: Caption) {
        guard canEditStructure, let index = captions.firstIndex(where: { $0.id == caption.id }), let clip = clips.first(where: { $0.id == caption.clipID }) else { return }
        checkpointUndo(key: "caption-\(caption.id)")
        var value = caption
        let minimum = min(0.1, clip.duration)
        value.start = max(0, min(clip.duration - minimum, value.start))
        value.duration = max(minimum, min(clip.duration - value.start, value.duration))
        captions[index] = value; changed()
    }
    func deleteCaption(_ id: UUID) { guard canEditStructure else { return }; checkpointUndo(); captions.removeAll { $0.id == id }; changed() }
    func restoreCaptionOriginal(_ id: UUID) {
        guard canEditStructure, let index = captions.firstIndex(where: { $0.id == id }),
              let original = captions[index].originalTranscript, original != captions[index].text else { return }
        checkpointUndo(); captions[index].text = original
        plannedFingerprint = arrangementFingerprint
        changed(); status = "已还原识别原文，时间和样式保持原值。⌘Z 可撤销。"
    }
    func fillClip(_ id: UUID) {
        guard var caption = captions.first(where: { $0.id == id }), let clip = clips.first(where: { $0.id == caption.clipID }) else { return }
        caption.start = 0; caption.duration = clip.duration; updateCaption(caption)
    }
    func updateClip(_ clip: MediaClip) {
        guard canEditStructure, let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        checkpointUndo(key: "clip-\(clip.id)")
        pause(); var value = clip
        let lowerBound = value.sourceStart ?? 0
        let minimum = min(0.1, max(1.0 / 30, value.sourceDuration - lowerBound))
        value.trimStart = max(lowerBound, min(value.trimStart, max(lowerBound, value.sourceDuration - minimum)))
        value.duration = max(minimum, min(value.duration, value.kind == .video ? value.sourceDuration - value.trimStart : 30))
        value.timingLocked = true
        clips[index] = value
        for captionIndex in captions.indices where captions[captionIndex].clipID == clip.id {
            let minimum = min(0.1, value.duration)
            captions[captionIndex].start = max(0, min(value.duration - minimum, captions[captionIndex].start))
            captions[captionIndex].duration = max(minimum, min(value.duration - captions[captionIndex].start, captions[captionIndex].duration))
        }
        currentTime = min(currentTime, totalDuration); syncPlayer(force: true); changed()
    }
    func moveClip(_ id: UUID, by amount: Int) {
        guard canEditStructure, let i = clips.firstIndex(where: { $0.id == id }), clips.indices.contains(i + amount) else { return }
        checkpointUndo()
        pause(); clips.swapAt(i, i + amount); orderMode = .manual; orderSummary = "已手动调整顺序，后续导入会追加到末尾。"; seek(to: clips.startTime(of: id)); changed()
    }
    func removeClip(_ id: UUID) {
        guard canEditStructure, let index = clips.firstIndex(where: { $0.id == id }) else { return }
        checkpointUndo()
        pause(); clips.removeAll { $0.id == id }; captions.removeAll { $0.clipID == id }; thumbnails[id] = nil
        selectedClipID = clips.isEmpty ? nil : clips[min(index, clips.count - 1)].id
        if let captionID = selectedCaptionID, !captions.contains(where: { $0.id == captionID }) { selectedCaptionID = nil }
        currentTime = selectedClipID.map { clips.startTime(of: $0) } ?? 0
        syncPlayer(force: true); status = "已从项目移除素材，原文件保留。⌘Z 可撤销。"; changed()
    }
    func sortByName() {
        setOrderMode(.filename)
    }

    func setOrderMode(_ mode: ClipOrderMode) {
        guard canEditStructure else { return }
        if mode == .manual || clips.isEmpty {
            guard mode != orderMode else { return }
            checkpointUndo(); orderMode = mode
            orderSummary = mode == .manual ? "保留当前顺序，可在片段设置中前移或后移。" : "新导入素材会按\(mode.rawValue)排列。"
            changed(); return
        }
        _ = beginOrdering(mode: mode, arrangeAfter: true)
    }
    func reapplyOrder() {
        guard canEditStructure, !clips.isEmpty, orderMode != .manual else { return }
        _ = beginOrdering(mode: orderMode, arrangeAfter: true)
    }
    func cancelOrdering() { orderingTask?.cancel() }
    @discardableResult
    func waitForOrdering() async -> Bool {
        guard let task = orderingTask else { return true }
        return await task.value
    }
    private func beginOrdering(mode: ClipOrderMode, arrangeAfter: Bool, recordUndo: Bool = true) -> Task<Bool, Never> {
        pause(); isOrdering = true; orderProgress = 0
        orderSummary = "正在按\(mode.rawValue)整理故事顺序…"; status = orderSummary
        let generation = UUID(); orderingGeneration = generation
        let original = clips
        let anchor = clips.location(at: currentTime)
        let task = Task { [self] in
            do {
                var inputs = original
                for index in inputs.indices {
                    try Task.checkCancellation()
                    if inputs[index].importOrder == nil { inputs[index].importOrder = index }
                    if (mode == .chronological || mode == .story), inputs[index].capturedAt == nil, inputs[index].fileCreatedAt == nil,
                       let metadata = try? await MediaEngine.inspect(url: inputs[index].livePhotoStillURL ?? inputs[index].url) {
                        inputs[index].capturedAt = metadata.capturedAt; inputs[index].fileCreatedAt = metadata.fileCreatedAt
                    }
                }
                let result = try await StoryOrderEngine.arrange(clips: inputs, mode: mode) { [weak self] progress, message in
                    Task { @MainActor in
                        guard let self, self.isOrdering, self.orderingGeneration == generation else { return }
                        self.orderProgress = max(0, min(1, progress)); self.orderSummary = message
                    }
                }
                try Task.checkCancellation()
                guard !isTerminating, orderingGeneration == generation else { throw CancellationError() }
                guard Set(result.clips.map(\.id)) == Set(original.map(\.id)), result.clips.count == original.count else {
                    throw StudioError.message("排序结果不完整，已保留原顺序。")
                }
                let needsCheckpoint = clips != result.clips || orderMode != mode
                if recordUndo && needsCheckpoint { checkpointUndo() }
                clips = result.clips; orderMode = mode
                if let anchor { currentTime = clips.startTime(of: anchor.clip.id) + min(anchor.offset, max(0, anchor.clip.duration - 1.0 / 30)) }
                syncPlayer(force: true); syncMusic()
                orderProgress = 1; orderSummary = result.summary; status = result.summary
                isOrdering = false; orderingTask = nil; changed()
                if arrangeAfter, automaticEditEnabled { _ = beginAutomaticEdit(recordUndo: recordUndo && !needsCheckpoint) }
                return true
            } catch {
                guard orderingGeneration == generation else { return false }
                orderSummary = Task.isCancelled ? "已取消排序，保留原顺序。" : "排序未完成，保留原顺序。"
                status = orderSummary; isOrdering = false; orderingTask = nil
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                return false
            }
        }
        orderingTask = task
        return task
    }

    func setProjectTitle(_ value: String) {
        guard canEditStructure, title != value else { return }
        checkpointUndo(key: "title"); title = value; changed()
    }
    func setVideoFormat(_ value: VideoFormat) {
        guard canEditStructure, format != value else { return }
        checkpointUndo(); format = value; changed()
    }
    func setMusicSelection(_ value: String?) {
        guard canEditStructure, musicID != value else { return }
        checkpointUndo(); musicID = value; musicChanged()
    }
    func setMusicVolume(_ value: Double) {
        guard canEditStructure, value.isFinite else { return }
        let gain = max(0, min(1, value))
        guard gain != musicVolume else { return }
        checkpointUndo(key: "music-volume"); musicVolume = gain
        musicPlayer.volume = Float(gain); musicPreviewPlayer.volume = Float(gain); changed()
    }

    func setAutomaticEditEnabled(_ value: Bool) {
        guard canEditStructure, value != automaticEditEnabled else { return }
        checkpointUndo(); automaticEditEnabled = value; changed()
        if value { arrangeAutomatically() }
        else { autoEditSummary = "自动编排已关闭，导出会使用当前时间轴。" }
    }
    func unlockTiming(_ id: UUID) {
        guard canEditStructure, let index = clips.firstIndex(where: { $0.id == id }), clips[index].timingLocked == true else { return }
        checkpointUndo(); clips[index].timingLocked = nil; changed()
        if automaticEditEnabled { arrangeAutomatically() }
    }
    func arrangeAutomatically() {
        guard automaticEditEnabled, canEditStructure, !clips.isEmpty else { return }
        _ = beginAutomaticEdit()
    }
    // Includes caption changes and the music source, so export never reuses a stale plan.
    private var arrangementFingerprint: Data? {
        struct FileRevision: Encodable { var url: URL; var size: Int?; var modified: Date? }
        struct Input: Encodable { var clips: [MediaClip]; var captions: [Caption]; var music: URL?; var revisions: [FileRevision] }
        let urls = Array(Set(clips.map(\.url) + clips.compactMap(\.livePhotoStillURL) + [selectedMusicURL].compactMap { $0 })).sorted { $0.absoluteString < $1.absoluteString }
        let revisions = urls.map { url -> FileRevision in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return FileRevision(url: url, size: values?.fileSize, modified: values?.contentModificationDate)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Input(clips: clips, captions: captions, music: selectedMusicURL, revisions: revisions))
    }
    @discardableResult
    private func beginAutomaticEdit(recordUndo: Bool = true) -> Task<Bool, Never> {
        pause(); isAutoEditing = true; autoEditProgress = 0
        autoEditSummary = "正在分析画面内容与音乐节奏…"; status = autoEditSummary
        let generation = UUID(); autoEditGeneration = generation
        let sourceClips = clips, sourceCaptions = captions, music = selectedMusicURL
        let anchor = clips.location(at: currentTime)
        let task = Task { [self] in
            do {
                let result = try await AutoEditEngine.plan(clips: sourceClips, captions: sourceCaptions, musicURL: music) { [weak self] progress, message in
                    Task { @MainActor in
                        guard let self, self.autoEditGeneration == generation, self.isAutoEditing else { return }
                        self.autoEditProgress = max(0, min(1, progress)); self.autoEditSummary = message
                    }
                }
                try Task.checkCancellation()
                guard !isTerminating, autoEditGeneration == generation else { return false }
                if recordUndo && (result.clips != clips || result.captions != captions) { checkpointUndo() }
                clips = result.clips; captions = result.captions
                if let anchor, let clip = clips.first(where: { $0.id == anchor.clip.id }) {
                    currentTime = clips.startTime(of: clip.id) + min(anchor.offset, max(0, clip.duration - 1.0 / 30))
                } else { currentTime = 0 }
                syncPlayer(force: true); syncMusic()
                plannedFingerprint = arrangementFingerprint
                autoEditProgress = 1; autoEditSummary = result.summary; status = result.summary
                isAutoEditing = false; autoEditTask = nil; changed()
                return true
            } catch {
                guard autoEditGeneration == generation else { return false }
                autoEditSummary = Task.isCancelled ? "已取消编排，保留原时间轴。" : "编排未完成，保留原时间轴。"
                status = autoEditSummary
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                isAutoEditing = false; autoEditTask = nil
                return false
            }
        }
        autoEditTask = task
        return task
    }
    func cancelAutomaticEdit() { autoEditTask?.cancel() }
    @discardableResult
    func ensureAutomaticEdit() async -> Bool {
        if let task = autoEditTask { return await task.value }
        guard automaticEditEnabled, !clips.isEmpty else { return true }
        guard canEditStructure else { return false }
        if plannedFingerprint == arrangementFingerprint { return true }
        return await beginAutomaticEdit().value
    }

    private func checkpointUndo(key: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        if key == nil || key != lastUndoKey || now - lastUndoTime > 0.9 {
            undoHistory.append(document)
            if undoHistory.count > 50 { undoHistory.removeFirst() }
        }
        lastUndoKey = key; lastUndoTime = now
        redoHistory = []; undoCount = undoHistory.count; redoCount = 0
    }
    func undoEdit() {
        guard canEditStructure, let previous = undoHistory.popLast() else { return }
        redoHistory.append(document); restoreSnapshot(previous)
        lastUndoKey = nil; undoCount = undoHistory.count; redoCount = redoHistory.count
        status = "已撤销上一处修改。"; changed()
    }
    func redoEdit() {
        guard canEditStructure, let next = redoHistory.popLast() else { return }
        undoHistory.append(document); restoreSnapshot(next)
        lastUndoKey = nil; undoCount = undoHistory.count; redoCount = redoHistory.count
        status = "已重做修改。"; changed()
    }
    private func clearHistory() { undoHistory = []; redoHistory = []; undoCount = 0; redoCount = 0; lastUndoKey = nil }
    private func restoreSnapshot(_ doc: ProjectDocument) {
        pause(); cancelMusicWork(); resetCaptionEditingForProjectChange()
        title = doc.title; clips = doc.clips; captions = doc.captions; format = doc.format
        companionProfile = (doc.companionProfile ?? .classic).normalized()
        musicID = doc.musicID; customMusicURL = doc.customMusicURL; musicVolume = doc.musicVolume
        downloadedMusic = doc.downloadedMusic ?? []
        speechMode = doc.speechMode ?? recommendedSpeechMode
        speechVocabularyText = (doc.speechVocabulary ?? []).joined(separator: "\n")
        automaticEditEnabled = doc.automaticEditEnabled ?? false
        orderMode = doc.orderMode ?? .manual
        orderSummary = "已恢复项目中的\(orderMode.rawValue)，导出不会自行重排。"
        // Undo/redo expresses acceptance of this exact timeline. Do not silently redo
        // the just-undone automatic edit when the user exports it.
        plannedFingerprint = arrangementFingerprint
        autoEditSummary = automaticEditEnabled ? "已恢复这份时间轴；修改素材、文字或配乐后会重新编排。" : "自动编排已关闭，导出会使用当前时间轴。"
        selectedClipID = clips.first?.id; selectedCaptionID = nil; currentTime = 0
        thumbnails = [:]
        syncPlayer(force: true); syncMusic(replace: true); refreshMissingProjectAssets()
        refreshThumbnails()
    }

    private func refreshThumbnails(for requestedClips: [MediaClip]? = nil) {
        let generation = musicProjectGeneration, snapshot = requestedClips ?? clips
        let request = UUID()
        for clip in snapshot { thumbnailRequests[clip.id] = request }
        Task { [weak self] in
            for clip in snapshot {
                let image = await MediaEngine.thumbnail(for: clip)
                guard let self, !self.isTerminating, self.musicProjectGeneration == generation else { return }
                guard self.thumbnailRequests[clip.id] == request else { continue }
                guard self.clips.contains(where: { $0.id == clip.id && $0.url == clip.url && $0.trimStart == clip.trimStart && $0.livePhotoStillURL == clip.livePhotoStillURL }) else { continue }
                self.thumbnails[clip.id] = image
                self.thumbnailRequests[clip.id] = nil
            }
        }
    }

    private static func readableAsset(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]),
              values.isRegularFile == true, values.ubiquitousItemDownloadingStatus != .notDownloaded else { return false }
        return true
    }
    func refreshMissingProjectAssets() {
        let previouslyMissing = Set(missingProjectAssets.map(\.url))
        var assets: [MissingProjectAsset] = [], seen = Set<String>()
        for clip in clips {
            let stillMissing = clip.livePhotoStillURL.map { !Self.readableAsset($0) } ?? false
            guard !Self.readableAsset(clip.url) || stillMissing else { continue }
            let isLive = clip.livePhotoStillURL != nil
            let id = "media:" + clip.url.standardizedFileURL.absoluteString
            guard seen.insert(id).inserted else { continue }
            assets.append(MissingProjectAsset(id: id, url: !Self.readableAsset(clip.url) ? clip.url : clip.livePhotoStillURL!,
                label: clip.name, kind: isLive ? .livePhoto : (clip.kind == .image ? .image : .video), clipID: clip.id))
        }
        if let url = selectedMusicURL, !Self.readableAsset(url) {
            assets.append(MissingProjectAsset(id: "music:" + url.standardizedFileURL.absoluteString,
                url: url, label: musicTracks.first(where: { $0.id == musicID })?.name ?? url.lastPathComponent, kind: .music))
        }
        missingProjectAssets = assets
        // Files can return to their original paths without a relink operation. Rebuild
        // only the resources that crossed from missing to readable; an ordinary
        // foreground check must not restart video decoding or change the playhead.
        let restoredClips = clips.filter { clip in
            (previouslyMissing.contains(clip.url) && Self.readableAsset(clip.url)) ||
            (clip.livePhotoStillURL.map { previouslyMissing.contains($0) && Self.readableAsset($0) } ?? false)
        }
        if let current = currentClip, current.kind == .video,
           previouslyMissing.contains(current.url), Self.readableAsset(current.url) {
            playerClipID = nil; playerClipURL = nil
            syncPlayer(force: true)
        }
        if let music = selectedMusicURL, previouslyMissing.contains(music), Self.readableAsset(music) {
            syncMusic(replace: true)
        }
        if !restoredClips.isEmpty { refreshThumbnails(for: restoredClips) }
    }
    func locateMissingAsset(_ asset: MissingProjectAsset) {
        guard canEditSpeechSettings, !isShowingSpeechSettings, !isRelinkingAssets else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = asset.kind == .music ? [.audio] : (asset.kind == .livePhoto ? [.image, .movie] : (asset.kind == .image ? [.image] : [.movie]))
        panel.allowsMultipleSelection = asset.kind == .livePhoto
        panel.prompt = "重新关联"
        panel.message = asset.kind == .livePhoto ? "请同时选择这张实况的原照片和配对 MOV。核验通过后会保留原来的感想和剪辑。" : "重新选择“\(asset.label)”的原文件。保留原来的感想、顺序和剪辑时间。"
        assetRelinkIssue = nil
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { [weak self] in
            guard let self else { return }
            do { try await self.relinkAsset(asset, to: urls) }
            catch { self.assetRelinkIssue = error.localizedDescription }
        }
    }
    func relinkAsset(_ asset: MissingProjectAsset, to urls: [URL]) async throws {
        guard canEditSpeechSettings, !isShowingSpeechSettings, !isRelinkingAssets else { throw StudioError.message("请先结束当前操作，再重新关联素材。") }
        guard !urls.isEmpty, urls.allSatisfy({ Self.readableAsset($0) }) else { throw StudioError.message("所选文件无法读取，请先把原文件下载或复制到 Mac。") }
        isRelinkingAssets = true; assetRelinkIssue = nil; pause()
        defer { isRelinkingAssets = false }
        let generation = musicProjectGeneration
        var replacementClips = clips
        var newCustomMusicURL = customMusicURL
        var newMusicID = musicID
        if asset.kind == .music {
            guard selectedMusicURL == asset.url else { throw StudioError.message("当前配乐已改变，请重新检查素材列表。") }
            guard urls.count == 1, let url = urls.first else { throw StudioError.message("请选择一份配乐文件。") }
            let audio = AVURLAsset(url: url)
            guard try await audio.load(.isPlayable), !(try await audio.loadTracks(withMediaType: .audio)).isEmpty else {
                throw StudioError.message("所选文件没有可播放的音轨，请重新选择配乐原文件。")
            }
            if customMusicURL == asset.url { newCustomMusicURL = url }
            if musicID != "custom", !downloadedMusic.contains(where: { "online:" + $0.id == musicID }) {
                newMusicID = "custom"; newCustomMusicURL = url
            }
        } else {
            guard let clipID = asset.clipID, let original = clips.first(where: { $0.id == clipID }) else { throw StudioError.message("这份素材已不在当前项目中，请重新检查。") }
            let replacement: MediaClip
            var newStill: URL?, newAssetID: String?
            if asset.kind == .livePhoto {
                let candidates = await LivePhotoImporter.prepare(urls: urls)
                guard urls.count == 2, candidates.count == 1, let candidate = candidates.first, let still = candidate.stillURL,
                      original.livePhotoAssetID == nil || candidate.livePhotoAssetID == original.livePhotoAssetID else {
                    throw StudioError.message("这两份文件不是原实况的有效配对。请同时选择同一张实况的原照片和 MOV。")
                }
                replacement = try await MediaEngine.inspect(url: candidate.url)
                newStill = still; newAssetID = candidate.livePhotoAssetID
            } else {
                guard urls.count == 1, let url = urls.first else { throw StudioError.message("请为这段素材选择一个原文件。") }
                replacement = try await MediaEngine.inspect(url: url)
                guard replacement.kind == original.kind else { throw StudioError.message("素材类型不一致，请选择原来的\(asset.kind.rawValue)文件。") }
                if original.livePhotoAssetID != nil {
                    newAssetID = await LivePhotoImporter.prepare(urls: [url]).first?.livePhotoAssetID
                }
            }
            for index in replacementClips.indices where replacementClips[index].url == original.url {
                let old = replacementClips[index]
                if old.kind == .video {
                    guard old.trimStart >= (replacement.sourceStart ?? 0) - 0.001,
                          old.trimStart + old.duration <= replacement.sourceDuration + 0.001 else {
                        throw StudioError.message("所选视频无法覆盖原剪辑的 \(timeLabel(old.trimStart))–\(timeLabel(old.trimStart + old.duration))。请重新选择完整原片；现有文字和剪辑已保留。")
                    }
                }
                replacementClips[index].url = replacement.url
                replacementClips[index].sourceDuration = replacement.sourceDuration
                replacementClips[index].sourceStart = replacement.sourceStart
                replacementClips[index].livePhotoStillURL = newStill
                replacementClips[index].livePhotoAssetID = newAssetID
            }
        }
        try Task.checkCancellation()
        guard !isTerminating, musicProjectGeneration == generation else { throw CancellationError() }
        checkpointUndo()
        cancelMusicWork()
        clips = replacementClips
        if asset.kind == .music, let url = urls.first {
            // A music download may finish while AVFoundation validates the file.
            // Repair only this URL in the current library, preserving new entries.
            downloadedMusic = downloadedMusic.map { original in
                var track = original
                if track.localURL == asset.url { track.localURL = url }
                return track
            }
            customMusicURL = newCustomMusicURL; musicID = newMusicID
        }
        // Relinking repairs storage. It never requests a different creative edit.
        plannedFingerprint = arrangementFingerprint
        thumbnails = [:]; playerClipID = nil; playerClipURL = nil
        syncPlayer(force: true); syncMusic(replace: true)
        refreshThumbnails(); refreshMissingProjectAssets(); changed()
        status = "已重新关联“\(asset.label)”，感想和剪辑保持原样。⌘Z 可撤销。"
    }
    private func checkExportAssets(includeMusic: Bool, captionedOnly: Bool = false) -> Bool {
        refreshMissingProjectAssets()
        let captionIDs = Set(captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.clipID))
        let blockers = missingProjectAssets.filter { asset in
            if asset.kind == .music { return includeMusic }
            // A missing Live Photo poster does not prevent exporting its movie.
            guard let clip = clips.first(where: { $0.id == asset.clipID }), !Self.readableAsset(clip.url) else { return false }
            return !captionedOnly || clips.contains(where: { $0.url == clip.url && captionIDs.contains($0.id) })
        }
        if !blockers.isEmpty {
            pause()
            assetRelinkIssue = nil; isShowingMissingAssets = true
            status = "先重新关联缺失素材，再导出作品。"
            return false
        }
        if includeMusic, musicID != nil, selectedMusicURL == nil {
            errorMessage = "当前配乐已不可用，请重新选择配乐，或选择不使用配乐后导出。"
            return false
        }
        return true
    }

    func exportVideo() {
        guard canEditStructure, !clips.isEmpty else { return }
        guard checkExportAssets(includeMusic: true) else { return }
        pause()
        Task {
            guard await ensureAutomaticEdit(), !isTerminating else { return }
            presentExportPanel()
        }
    }
    private func presentExportPanel() {
        guard canEditStructure, !clips.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(title.isEmpty ? "映述短片" : title).mp4"
        panel.message = "导出包含画面、文字与所选配乐的 MP4；口述录音和素材原声不会加入。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launchExport(to: url)
    }
    func startExport(to url: URL) {
        guard canEditStructure, !clips.isEmpty else { return }
        guard checkExportAssets(includeMusic: true) else { return }
        pause()
        Task {
            guard await ensureAutomaticEdit(), !isTerminating else { return }
            launchExport(to: url)
        }
    }
    private func launchExport(to url: URL) {
        guard canEditStructure, !clips.isEmpty else { return }
        isExporting = true; exportKindLabel = "短片"; exportProgress = 0; status = "正在制作短片，请保持映述运行…"
        let attribution = selectedMusicAttribution
        let capturedProfile = companionProfile
        let settings = ExportSettings(clips: clips, captions: captions, format: format, musicURL: selectedMusicURL, musicVolume: musicVolume, outputURL: url, companionProfile: capturedProfile)
        exportTask = Task { [self] in
            do {
                try await MediaEngine.export(settings: settings) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
                lastExportURL = url; exportProgress = 1; status = "短片已保存到 \(url.lastPathComponent)"
                status += saveMusicCredit(attribution, beside: url)
            } catch { if Task.isCancelled { status = "已取消导出。" } else { errorMessage = error.localizedDescription; status = "导出未完成，请查看错误后重试。" } }
            isExporting = false; exportTask = nil
        }
    }
    /// Sidecar failure never invalidates the verified MP4. Source files and project
    /// data remain protected even if an existing sidecar is a symbolic or hard link.
    func saveMusicCredit(_ attribution: String?, beside outputURL: URL) -> String {
        let creditURL = outputURL.deletingPathExtension().appendingPathExtension("music-credit.txt")
        func protectedDestination() -> Bool {
            let originals = clips.flatMap { [$0.url] + ($0.livePhotoStillURL.map { [$0] } ?? []) }
                + (customMusicURL.map { [$0] } ?? []) + downloadedMusic.map(\.localURL)
                + (selectedMusicURL.map { [$0] } ?? []) + (projectURL.map { [$0] } ?? [])
                + [autosaveURL, outputURL]
            return originals.contains { Self.sameFile($0, creditURL) }
        }
        guard !protectedDestination() else {
            return attribution == nil
                ? "；旧署名文件位置与项目或素材冲突，已保留原文件。"
                : "；署名文件位置与项目或素材冲突，已保留原文件，请从配乐区域复制署名。"
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: creditURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return attribution == nil
                ? "；旧署名文件位置是文件夹，已保留其中内容。"
                : "；署名文件位置是文件夹，已保留其中内容，请从配乐区域复制署名。"
        }
        if let attribution {
            do {
                try (attribution + "\n\n配乐已随画面剪裁/循环并与视频组合。请将上述署名和许可链接保留在发布说明中。\n").write(to: creditURL, atomically: true, encoding: .utf8)
                return "；配乐署名已另存为文本。"
            } catch {
                // Atomic writing leaves the previous file intact on failure. Keep it:
                // another process may have changed this path into a folder or source.
                return "；署名文件未能写入，请从配乐区域复制署名，勿使用旧署名文件。"
            }
        }
        if FileManager.default.fileExists(atPath: creditURL.path) {
            // unlink never removes a directory recursively, even if this destination
            // changes after the directory check above.
            let result = creditURL.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.unlink($0) } ?? -1
            }
            if result != 0 { return "；旧配乐署名文件未能清理，本次视频请勿使用它。" }
        }
        return ""
    }
    func exportCaptionImages() {
        guard canEditStructure, captions.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        guard checkExportAssets(includeMusic: false, captionedOnly: true) else { return }
        pause()
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "导出图片"
        panel.message = "导出带文字的画面为 PNG：每种分时文字各一张，视频与实况会截取对应帧。会新建一个文件夹，供剪映或抖音继续配乐。"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        startCaptionImageExport(to: directory)
    }
    func startCaptionImageExport(to directory: URL) {
        guard canEditStructure, !clips.isEmpty else { return }
        guard checkExportAssets(includeMusic: false, captionedOnly: true) else { return }
        pause(); isExporting = true; exportKindLabel = "带字图片"; exportProgress = 0
        status = "正在导出带文字的图片…"
        let snapshot = clips, words = captions, canvas = format, capturedProfile = companionProfile
        exportTask = Task { [self] in
            do {
                let images = try await CaptionImageExporter.export(clips: snapshot, captions: words, format: canvas, to: directory, companionProfile: capturedProfile) { [weak self] p in
                    Task { @MainActor in self?.exportProgress = p }
                }
                guard let first = images.first else { throw StudioError.message("没有可导出的带字画面。") }
                lastExportURL = first.deletingLastPathComponent(); exportProgress = 1
                status = "已导出 \(images.count) 张带字图片，可在剪映或抖音中继续配乐。"
            } catch {
                if Task.isCancelled || error is CancellationError { status = "已取消图片导出。" }
                else { errorMessage = error.localizedDescription; status = "图片导出未完成，原素材保留。" }
            }
            isExporting = false; exportTask = nil
        }
    }
    func cancelExport() { exportTask?.cancel(); MediaEngine.cancelExport() }
    func revealExport() { if let lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([lastExportURL]) } }

    var document: ProjectDocument { ProjectDocument(title: title, clips: clips, captions: captions, format: format, musicID: musicID, customMusicURL: customMusicURL, musicVolume: musicVolume, automaticEditEnabled: automaticEditEnabled, orderMode: orderMode, downloadedMusic: downloadedMusic.isEmpty ? nil : downloadedMusic, speechMode: speechMode, speechVocabulary: speechVocabulary.isEmpty ? nil : speechVocabulary, companionProfile: companionProfile) }
    var autosaveURL: URL {
        if let recoveryFileURL { return recoveryFileURL }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YingShu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Autosave.yingshu")
    }
    var recoverySaveLabel: String {
        switch recoverySaveState {
        case .idle: return "尚无恢复副本"
        case .pending: return "正在保存恢复副本…"
        case .saved: return "恢复副本已保存"
        case .failed: return "恢复副本保存失败"
        case .disabled: return "自动恢复未启用"
        }
    }
    var recoverySaveDetail: String {
        switch recoverySaveState {
        case .failed(let message): return "\(message)\n可重试，或用 ⌘S 将项目保存到其他位置。"
        case .saved(let date):
            return "\(date.formatted(date: .omitted, time: .standard)) 已保存本机恢复副本。⌘S 保存项目文件；原始素材仍需保留。"
        case .pending: return "正在将本次修改写入本机恢复副本。⌘S 可保存项目文件。"
        case .idle: return "开始编辑后会保存本机恢复副本；⌘S 可保存项目文件。"
        case .disabled: return "本次运行未启用自动恢复。"
        }
    }
    var hasRecoverySaveFailure: Bool { if case .failed = recoverySaveState { return true }; return false }
    private func projectSnapshotForComparison(_ source: ProjectDocument) -> ProjectDocument {
        var normalized = source
        normalized.recoveryProjectURL = nil
        normalized.companionProfile = (source.companionProfile ?? .classic).normalized()
        normalized.automaticEditEnabled = source.automaticEditEnabled ?? false
        normalized.orderMode = source.orderMode ?? .manual
        normalized.downloadedMusic = (source.downloadedMusic?.isEmpty ?? true) ? nil : source.downloadedMusic
        let mode = source.speechMode ?? recommendedSpeechMode
        normalized.speechMode = mode
        let terms = (source.speechVocabulary ?? []).flatMap {
            $0.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r"))
        }
        let vocabulary = SpeechRecognitionOptions(mode: mode, contextualStrings: terms).contextualStrings
        normalized.speechVocabulary = vocabulary.isEmpty ? nil : vocabulary
        return normalized
    }
    private func updateProjectDirtyState() {
        let current = projectSnapshotForComparison(document)
        hasUnsavedProjectChanges = (savedProjectSnapshot ?? emptyProjectSnapshot).map { projectSnapshotForComparison($0) != current } ?? false
    }
    func changed() {
        updateProjectDirtyState()
        guard autosaveEnabled else { return }
        saveTask?.cancel()
        recoverySaveState = .pending
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveRecoveryCopy()
        }
    }
    private func write(_ value: ProjectDocument, to url: URL) throws {
        guard url.isFileURL else { throw StudioError.message("请选择本机项目保存位置。") }
        let sources = clips.flatMap { [$0.url] + ($0.livePhotoStillURL.map { [$0] } ?? []) }
            + (customMusicURL.map { [$0] } ?? []) + downloadedMusic.map(\.localURL)
        guard !sources.contains(where: { Self.sameFile($0, url) }) else {
            throw StudioError.message("项目文件不能覆盖原始素材或配乐，请换一个保存位置。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let a = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let b = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let aID = a[.systemFileNumber] as? NSNumber, let bID = b[.systemFileNumber] as? NSNumber,
              let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber else { return false }
        return aID == bID && aDevice == bDevice
    }
    func writeDocument(to url: URL) throws { try write(document, to: url) }
    private func saveRecoveryCopy() {
        var recovery = document; recovery.recoveryProjectURL = projectURL
        do {
            try write(recovery, to: autosaveURL)
            recoverySaveState = .saved(Date())
        } catch {
            recoverySaveState = .failed(error.localizedDescription)
            status = "恢复副本保存失败，请重试或另存项目。"
        }
    }
    func retryRecoverySave() { flushAutosave() }
    func flushAutosave() {
        guard autosaveEnabled else { return }
        saveTask?.cancel()
        saveTask = nil
        saveRecoveryCopy()
    }
    func prepareToTerminate() async {
        isTerminating = true
        pause(); cancelMusicWork()
        cancelCaptionCleanup(); cancelEnhancedSpeechPreparation()
        captionEditingTask?.cancel()
        if let task = photoLibraryTask { task.cancel(); await task.value }
        if let task = orderingTask { task.cancel(); _ = await task.value }
        if let task = autoEditTask { task.cancel(); _ = await task.value }
        if isCheckingSpeech { speech.cancel(); isCheckingSpeech = false }
        // Give an existing take a short chance to finish, without keeping the app
        // in terminateLater for a model's full (possibly minutes-long) deadline.
        var terminationFinish: Task<Void, Never>?
        if speech.isRecording { terminationFinish = Task { await finishRecording(autoResume: false) } }
        if isTranscribing || speech.isRecording {
            let deadline = ProcessInfo.processInfo.systemUptime + terminationSpeechGracePeriod
            while (isTranscribing || speech.isRecording), ProcessInfo.processInfo.systemUptime < deadline {
                if isTranscribing && recordWallStart == nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if isTranscribing || speech.isRecording {
                recordingGeneration = UUID()
                let partial = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if let anchor = recordAnchor, !partial.isEmpty {
                    _ = saveRecordingText(partial, anchor: anchor, endTime: currentTime)
                }
                speech.cancel(); recordingTask?.cancel(); recordingTask = nil
                isTranscribing = false; clearRecordingContext()
            }
        }
        terminationFinish?.cancel()
        if isExporting {
            cancelExport()
            for _ in 0..<50 {
                if !isExporting { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        flushAutosave()
        localAIWarmupTask?.cancel(); localAIWarmupTask = nil
        LocalAIVoiceService.shared.cancelCurrentRequest()
    }
    private func preserveCurrentProject() throws {
        guard !clips.isEmpty else { return }
        let directory = autosaveURL.deletingLastPathComponent().appendingPathComponent("Recovered Projects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try writeDocument(to: directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(6)).yingshu.json"))
    }
    func showRecoveredProjects() {
        let directory = autosaveURL.deletingLastPathComponent().appendingPathComponent("Recovered Projects")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
    func saveProject() {
        guard canEditStructure else { return }
        if let url = projectURL {
            do { try saveProject(to: url) } catch { errorMessage = "项目未能保存：\(error.localizedDescription)" }
        } else { saveProjectAs() }
    }
    func saveProjectAs() {
        guard canEditStructure else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(title).yingshu.json"
        panel.message = "项目保存素材路径和文字。请保留原始照片、视频和自选音乐。"
        if let projectURL { panel.directoryURL = projectURL.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            do { try saveProject(to: url) } catch { errorMessage = "项目未能保存：\(error.localizedDescription)" }
        }
    }
    func saveProject(to url: URL) throws {
        try writeDocument(to: url)
        projectURL = url; savedProjectSnapshot = document; updateProjectDirtyState()
        // Keep the named project's location in the local recovery copy, so ⌘S
        // continues to mean Save after restarting the app.
        flushAutosave()
        status = "项目已保存到 \(url.lastPathComponent)。"
    }
    func openProject() {
        guard canEditStructure else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .data]
        if panel.runModal() == .OK, let url = panel.url { do { try preserveCurrentProject(); try applyDocument(from: url) } catch { errorMessage = error.localizedDescription } }
    }
    func newProject() {
        guard canEditStructure else { return }
        if !clips.isEmpty {
            let alert = NSAlert(); alert.messageText = "开始新的手记？"; alert.informativeText = "当前项目会自动保留一份，可从“文件 → 查看自动保留的项目”找回。"; alert.addButton(withTitle: "开始新项目"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try preserveCurrentProject() } catch { errorMessage = "无法保留当前项目：\(error.localizedDescription)"; return }
        pause(); cancelMusicWork(); resetCaptionEditingForProjectChange(); speechMode = recommendedSpeechMode; speechVocabularyText = ""; companionProfile = Self.savedCompanionProfile(in: profileDefaults); clips = []; captions = []; thumbnails = [:]; selectedClipID = nil; selectedCaptionID = nil; currentTime = 0; title = "我的旅行手记"; projectURL = nil; lastExportURL = nil; plannedFingerprint = nil; musicID = "breeze"; customMusicURL = nil; musicVolume = 0.32; downloadedMusic = []; format = .landscape; automaticEditEnabled = true; autoEditSummary = "导入后会按画面内容与所选音乐安排节奏。"; orderMode = .chronological; orderSummary = "默认按拍摄时间串起旅程，也可选择智能叙事。"; clearImportSummary(); missingProjectAssets = []; syncPlayer(force: true); syncMusic(replace: true); emptyProjectSnapshot = document; savedProjectSnapshot = document; changed()
        clearHistory()
    }
    private func restoreAutosave() {
        guard FileManager.default.fileExists(atPath: autosaveURL.path) else { return }
        do {
            try applyDocument(from: autosaveURL, isRecovery: true)
            recoverySaveState = .saved((try? autosaveURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        } catch {
            // Preserve a corrupt recovery file before a future edit can replace it.
            let backup = autosaveURL.deletingLastPathComponent().appendingPathComponent("Unreadable-Recovery-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: autosaveURL, to: backup)
                status = "上次恢复副本无法打开，原文件已保留为 \(backup.lastPathComponent)。可重新打开项目。"
            } catch { status = "上次项目未能恢复，请先从原项目文件打开。" }
            recoverySaveState = .failed("上次恢复副本无法读取，请打开已有项目或另存当前项目。")
        }
    }
    private func readDocument(from url: URL) throws -> ProjectDocument {
        guard url.isFileURL else { throw StudioError.message("请选择本机项目文件。") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 * 1024 else {
            throw StudioError.message("项目文件过大或不是普通文件，当前支持 64 MB 以内的项目。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw StudioError.message("项目文件超过 64 MB。") }
        return try JSONDecoder().decode(ProjectDocument.self, from: data)
    }
    func applyDocument(from url: URL, isRecovery: Bool = false) throws {
        let doc = try readDocument(from: url)
        let clipsByID = Dictionary(doc.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard doc.version == 1, doc.clips.count <= 10000,
              doc.captions.count <= 100000, doc.clips.totalDuration.isFinite,
              doc.clips.allSatisfy({ $0.url.isFileURL && $0.duration.isFinite && $0.duration >= 1.0 / 30 - 0.001 && $0.duration <= 86400 && $0.trimStart.isFinite && $0.trimStart >= ($0.sourceStart ?? 0) && ($0.sourceStart ?? 0).isFinite && ($0.sourceStart ?? 0) >= 0 && $0.sourceDuration.isFinite && $0.sourceDuration >= 1.0 / 30 - 0.001 && ($0.kind == .image || $0.trimStart + $0.duration <= $0.sourceDuration + 0.05) }),
              Set(doc.clips.map(\.id)).count == doc.clips.count,
              doc.clips.allSatisfy({ ($0.livePhotoStillURL == nil || ($0.kind == .video && $0.livePhotoStillURL!.isFileURL)) && ($0.capturedAt?.timeIntervalSince1970.isFinite ?? true) && ($0.fileCreatedAt?.timeIntervalSince1970.isFinite ?? true) && ($0.importOrder == nil || $0.importOrder! >= 0) }),
              Set(doc.captions.map(\.id)).count == doc.captions.count,
              doc.captions.allSatisfy({ c in c.start.isFinite && c.duration.isFinite && c.start >= 0 && c.duration > 0 && (clipsByID[c.clipID].map { c.start + c.duration <= $0.duration + 0.05 } ?? false) }),
              doc.musicVolume.isFinite && (0...1).contains(doc.musicVolume),
              (doc.customMusicURL == nil || doc.customMusicURL!.isFileURL),
              (doc.recoveryProjectURL == nil || doc.recoveryProjectURL!.isFileURL),
              (doc.downloadedMusic?.count ?? 0) <= 1000,
              (doc.downloadedMusic ?? []).allSatisfy({ $0.localURL.isFileURL && $0.sourceURL.scheme == "https" && $0.licenseURL.scheme == "https" && $0.attribution.count <= 20000 }),
              Set((doc.downloadedMusic ?? []).map(\.id)).count == (doc.downloadedMusic?.count ?? 0),
              (doc.speechVocabulary?.count ?? 0) <= 100,
              (doc.speechVocabulary ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              doc.captions.allSatisfy({ ($0.originalTranscript?.utf16.count ?? 0) <= 100_000 })
        else { throw StudioError.message("项目内容无效或版本不受支持。") }
        saveTask?.cancel(); saveTask = nil
        pause(); cancelMusicWork(); resetCaptionEditingForProjectChange(); title = doc.title; clips = doc.clips; captions = doc.captions; format = doc.format; musicID = doc.musicID; customMusicURL = doc.customMusicURL; musicVolume = doc.musicVolume
        companionProfile = (doc.companionProfile ?? .classic).normalized()
        downloadedMusic = doc.downloadedMusic ?? []
        speechMode = doc.speechMode ?? recommendedSpeechMode
        speechVocabularyText = (doc.speechVocabulary ?? []).joined(separator: "\n")
        automaticEditEnabled = doc.automaticEditEnabled ?? false
        orderMode = doc.orderMode ?? .manual
        orderSummary = "已恢复项目中的\(orderMode.rawValue)，导出不会自行重排。"
        plannedFingerprint = arrangementFingerprint
        autoEditSummary = automaticEditEnabled ? "已保留保存时的时间轴；修改素材、文字或配乐后会重新检查节奏。" : "自动编排已关闭，导出会使用当前时间轴。"
        clearHistory()
        thumbnails = [:]; currentTime = 0; selectedClipID = clips.first?.id; selectedCaptionID = nil
        lastExportURL = nil; clearImportSummary(); isShowingMissingAssets = false
        projectURL = isRecovery ? doc.recoveryProjectURL : url
        if isRecovery {
            savedProjectSnapshot = projectURL.flatMap { try? readDocument(from: $0) }.map(projectSnapshotForComparison)
        } else { savedProjectSnapshot = document }
        updateProjectDirtyState()
        playerClipID = nil; playerClipURL = nil
        syncPlayer(force: true); syncMusic(replace: true); refreshMissingProjectAssets()
        status = missingProjectAssets.isEmpty ? "已恢复项目，继续讲述你的故事。" : "有 \(missingProjectAssets.count) 份素材无法读取，可点击“重新关联”找回。"
        refreshThumbnails()
        if !isRecovery { changed() }
    }
    private func resetCaptionEditingForProjectChange() {
        assetRelinkIssue = nil
        cancelCaptionCleanup()
        captionEditingTask?.cancel(); captionEditingTask = nil
        cleanupAfterOpeningCaptionID = nil; captionCleanupOriginalText = nil
        editingCaptionID = nil; captionEditDraft = ""; captionEditIssue = nil
        isPreparingCaptionEdit = false; resumeAfterCaptionEditing = false
    }
}
