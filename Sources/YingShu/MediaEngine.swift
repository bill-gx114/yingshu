import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// Local, deterministic media assembly. Input recordings are never included in the output mix.
enum MediaEngine {
    private static let control = ExportControl()
    private static let timescale: CMTimeScale = 600
    private static let fps: Int32 = 30

    /// Non-nil means the URL cannot be imported as one local image/video; callers may skip it.
    static func importNotice(for url: URL) -> String? {
        guard url.isFileURL else { return "请先把照片或视频保存到 Mac，再导入本地文件。" }
        let ext = url.pathExtension.lowercased()
        if ["aae", "xmp"].contains(ext) {
            return "这是照片编辑信息侧车文件，不含照片或视频画面。请导入同批的 HEIC、JPEG 或 MOV；若要保留‘照片’里的编辑效果，请先导出编辑后的照片/视频。"
        }
        if ["photoslibrary", "photolibrary", "aplibrary"].contains(ext) {
            return "照片图库不是单个素材文件。请在 Mac‘照片’中选中素材，使用‘文件 → 导出’，再导入导出的照片或视频。"
        }
        if ext == "icloud" { return "这是尚未下载的 iCloud 占位文件。请先在 Finder 中下载原片，再导入实际的照片或视频文件。" }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]) {
            if values.isDirectory == true { return "请选择照片或视频文件；文件夹和应用/图库包不能作为一段素材导入。" }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return "这份 iCloud 原片尚未下载到 Mac。请在 Finder 中先下载原片，再重新导入。"
            }
            if values.isRegularFile == true && values.fileSize == 0 { return "这个文件是空的，尚无可读取的素材数据。请确认原片已完整下载或复制完成。" }
        }
        return nil
    }

    static func inspect(url: URL) async throws -> MediaClip {
        if let notice = importNotice(for: url) { throw StudioError.message(notice) }
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw StudioError.message("无法读取素材“\(url.lastPathComponent)”，请确认原文件仍在原位置。")
        }
        if decodedImage(url: url, maxDimension: 640) != nil {
            return MediaClip(url: url, name: url.deletingPathExtension().lastPathComponent,
                             kind: .image, duration: 4, sourceDuration: 30,
                             capturedAt: photoCapturedAt(url: url), fileCreatedAt: fileCreatedAt(url: url))
        }
        let rawExtensions = ["dng", "raw", "nef", "arw", "cr2", "cr3", "rw2", "raf", "orf", "pef", "srw", "nrw", "3fr"]
        if rawExtensions.contains(url.pathExtension.lowercased()) {
            throw StudioError.message("当前 Mac 无法解码这份 RAW/DNG 原片。请在‘照片’或相机软件中导出 JPEG/HEIC 后导入；DNG 扩展名并不保证具体相机/ProRAW版本兼容。")
        }
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(imageSource) != nil {
            throw StudioError.message("无法解码这张照片。文件可能尚未完整下载、已损坏，或当前 macOS 不支持其图片编码；请尝试从‘照片’导出 JPEG/HEIC 后导入。")
        }
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw StudioError.message("素材没有可读取的视频画面。")
            }
            // Audio can outlast the picture, and some phone files start the picture after zero.
            // Use the actual video interval so initial trim and all later edits stay valid.
            let range = try await pictureRange(of: track)
            let duration = range.duration.seconds
            let start = range.start.seconds
            guard duration.isFinite, start.isFinite, start >= 0, duration >= 1.0 / 30 - 0.001 else {
                throw StudioError.message("视频画面时长无效或短于一帧（1/30 秒）。")
            }
            guard try await asset.load(.isPlayable) else { throw StudioError.message("此视频格式无法在当前 Mac 播放。") }
            return MediaClip(url: url, name: url.deletingPathExtension().lastPathComponent,
                             kind: .video, duration: min(duration, 8), sourceDuration: start + duration, trimStart: start, sourceStart: start,
                             capturedAt: await videoCapturedAt(asset: asset), fileCreatedAt: fileCreatedAt(url: url))
        } catch {
            throw StudioError.message("无法导入“\(url.lastPathComponent)”：\(error.localizedDescription)")
        }
    }

    static func previewImage(url: URL) -> NSImage? {
        guard let cgImage = decodedImage(url: url, maxDimension: 3072) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func thumbnail(for clip: MediaClip) async -> NSImage? {
        if let stillURL = clip.livePhotoStillURL, let image = decodedImage(url: stillURL, maxDimension: 640) {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        if clip.kind == .image {
            guard let cgImage = decodedImage(url: clip.url, maxDimension: 640) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: clip.trimStart, preferredTimescale: timescale))
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch { return nil }
    }

    static func cancelExport() { control.cancel() }

    static func export(settings: ExportSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let token = try control.begin()
        defer { control.finish(token: token) }
        try await withTaskCancellationHandler {
            try await performExport(settings: settings, token: token, progress: progress)
        } onCancel: {
            control.cancel(token: token)
        }
    }

    private static func performExport(settings: ExportSettings, token: UUID,
                                      progress: @escaping @Sendable (Double) -> Void) async throws {
        try checkCancellation(token)
        guard !settings.clips.isEmpty else { throw StudioError.message("请先加入照片或视频。") }
        guard settings.outputURL.isFileURL else { throw StudioError.message("请选择本地 MP4 保存位置。") }
        try validateOutputDestination(settings.outputURL)
        let ids = Set(settings.clips.map(\.id))
        guard ids.count == settings.clips.count else { throw StudioError.message("素材标识重复，请重新导入重复的素材。") }
        for clip in settings.clips {
            try checkCancellation(token)
            guard clip.duration.isFinite, clip.duration >= 1.0 / 30 - 0.001,
                  clip.trimStart.isFinite, clip.trimStart >= 0 else {
                throw StudioError.message("“\(clip.name)”的起点或时长无效。")
            }
            guard clip.url.isFileURL, FileManager.default.isReadableFile(atPath: clip.url.path) else {
                throw StudioError.message("找不到素材“\(clip.name)”，请确认原文件仍在原位置。")
            }
            let originals = [clip.url] + (clip.livePhotoStillURL.map { [$0] } ?? [])
            guard !originals.contains(where: { referencesSameFile($0, settings.outputURL) }) else {
                throw StudioError.message("导出位置不能覆盖原始素材，请更换保存名称。")
            }
        }
        if let music = settings.musicURL {
            guard music.isFileURL, FileManager.default.isReadableFile(atPath: music.path) else {
                throw StudioError.message("找不到所选配乐“\(music.lastPathComponent)”。请重新选择，或关闭配乐后导出。")
            }
            guard !referencesSameFile(music, settings.outputURL) else {
                throw StudioError.message("导出位置不能覆盖配乐文件。")
            }
        }
        guard settings.musicVolume.isFinite else { throw StudioError.message("配乐音量无效。") }
        try validateCaptions(settings.captions, clips: settings.clips)
        let totalSeconds = settings.clips.totalDuration
        guard totalSeconds.isFinite, totalSeconds > 0, totalSeconds < 24 * 3600 else {
            throw StudioError.message("项目时长无效，或超过 24 小时。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingShu-\(token.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The original destination stays intact until a complete MP4 has been verified.
        let stagedOutput = settings.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".YingShu-\(token.uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.message("无法创建视频轨道。")
        }
        let canvas = settings.format.size
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        var actualClips: [(MediaClip, CMTime, CMTime)] = []
        var imageMovies: [URL: URL] = [:]
        let imageDurations = settings.clips.filter { $0.kind == .image }.reduce(into: [URL: Double]()) { durations, clip in
            let key = clip.url.standardizedFileURL.resolvingSymlinksInPath()
            durations[key] = max(durations[key] ?? 0, clip.duration)
        }
        progress(0)
        for (index, clip) in settings.clips.enumerated() {
            try checkCancellation(token)
            let sourceURL: URL
            var sourceStart: CMTime
            let requestedDuration = CMTime(seconds: clip.duration, preferredTimescale: timescale)
            if clip.kind == .image {
                let key = clip.url.standardizedFileURL.resolvingSymlinksInPath()
                if let cached = imageMovies[key] { sourceURL = cached }
                else {
                    sourceURL = temporary.appendingPathComponent("image-\(index).mp4")
                    let stillDuration = CMTime(seconds: imageDurations[key] ?? clip.duration, preferredTimescale: timescale)
                    try await imageMovie(source: clip.url, destination: sourceURL, size: canvas,
                                         duration: stillDuration, token: token)
                    imageMovies[key] = sourceURL
                }
                sourceStart = .zero
            } else {
                sourceURL = clip.url
                sourceStart = CMTime(seconds: clip.trimStart, preferredTimescale: timescale)
            }
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw StudioError.message("“\(clip.name)”没有可用的视频画面。")
            }
            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)
            let sourceRange = try await pictureRange(of: sourceTrack)
            let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            guard naturalSize.width.isFinite, naturalSize.height.isFinite,
                  oriented.width.isFinite, oriented.height.isFinite,
                  oriented.width > 0, oriented.height > 0 else {
                throw StudioError.message("“\(clip.name)”的视频尺寸无效。")
            }
            // Seconds are quantized to the project clock; preserve a precise first-frame start.
            let clockTolerance = 1.0 / Double(timescale) + 0.00001
            if sourceStart < sourceRange.start && sourceRange.start.seconds - sourceStart.seconds <= clockTolerance {
                sourceStart = sourceRange.start
            }
            // Do not silently stretch a truncated or missing source interval.
            let available = CMTimeSubtract(CMTimeRangeGetEnd(sourceRange), sourceStart)
            guard sourceStart >= sourceRange.start, available.seconds.isFinite, available.seconds > 0,
                  available.seconds + clockTolerance >= requestedDuration.seconds else {
                throw StudioError.message("“\(clip.name)”的裁剪范围超出原视频，请缩短片段或重新导入。")
            }
            let duration = CMTimeMinimum(available, requestedDuration)
            do {
                try videoTrack.insertTimeRange(CMTimeRange(start: sourceStart, duration: duration), of: sourceTrack, at: cursor)
            } catch {
                throw StudioError.message("无法拼接“\(clip.name)”：\(error.localizedDescription)")
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fitTransform(size: naturalSize, preferred: preferredTransform, canvas: canvas), at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            actualClips.append((clip, cursor, duration))
            cursor = CMTimeAdd(cursor, duration)
            progress(0.25 * Double(index + 1) / Double(settings.clips.count))
        }
        try checkCancellation(token)
        var mix: AVMutableAudioMix?
        if let musicURL = settings.musicURL {
            mix = try await addMusic(url: musicURL, volume: settings.musicVolume,
                                     to: composition, duration: cursor, token: token)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        videoComposition.instructions = instructions
        // Explicit SDR avoids source-dependent HDR export failures and makes the canvas predictable.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let captionClips = actualClips
        let captionDuration = cursor.seconds
        videoComposition.animationTool = try await captionTool(captions: settings.captions, clips: captionClips,
                                                                canvas: canvas, totalDuration: captionDuration, token: token)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioError.message("此 Mac 无法创建视频导出任务。")
        }
        guard exporter.supportedFileTypes.contains(.mp4) else { throw StudioError.message("当前素材无法编码为 MP4。") }
        exporter.outputURL = stagedOutput
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.audioMix = mix
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(start: .zero, duration: cursor)
        control.set(exporter: exporter, token: token)
        try checkCancellation(token)
        let progressTask = Task {
            while !Task.isCancelled {
                progress(min(0.98, 0.25 + Double(exporter.progress) * 0.72))
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
        defer { progressTask.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()
        await progressTask.value
        try checkCancellation(token)
        guard exporter.status == .completed else {
            if exporter.status == .cancelled { throw CancellationError() }
            throw StudioError.message("视频导出失败：\(exporter.error?.localizedDescription ?? "编码器未完成，请检查磁盘空间和素材格式。")")
        }
        let exportedAsset = AVURLAsset(url: stagedOutput)
        let exportedDuration = try await exportedAsset.load(.duration).seconds
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        let exportedAudio = try await exportedAsset.loadTracks(withMediaType: .audio)
        let exportedSize = try await exportedTracks.first?.load(.naturalSize)
        let byteCount = (try FileManager.default.attributesOfItem(atPath: stagedOutput.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard exportedSize == canvas, !exportedAudio.isEmpty == (settings.musicURL != nil),
              byteCount > 0, exportedDuration.isFinite, abs(exportedDuration - cursor.seconds) < 0.15 else {
            throw StudioError.message("导出文件校验失败，未替换原有文件。")
        }
        try checkCancellation(token)
        // Recheck after encoding: the save destination can change while a long export runs.
        try validateOutputDestination(settings.outputURL)
        let originals = settings.clips.flatMap { [$0.url] + ($0.livePhotoStillURL.map { [$0] } ?? []) }
        guard !originals.contains(where: { referencesSameFile($0, settings.outputURL) }),
              settings.musicURL.map({ !referencesSameFile($0, settings.outputURL) }) ?? true else {
            throw StudioError.message("导出位置现在指向原始素材或配乐，已停止保存。请更换保存名称。")
        }
        if FileManager.default.fileExists(atPath: settings.outputURL.path) {
            _ = try FileManager.default.replaceItemAt(settings.outputURL, withItemAt: stagedOutput)
        } else {
            try FileManager.default.moveItem(at: stagedOutput, to: settings.outputURL)
        }
        progress(1)
    }

    private static func validateOutputDestination(_ destination: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw StudioError.message("导出位置是一个文件夹，请为 MP4 选择文件名。已有文件夹没有被修改。")
        }
    }

    /// Paths can differ while referring to the same original (symlinks or hard links).
    /// Check both the resolved path and filesystem identity before replacing an existing output.
    private static func referencesSameFile(_ source: URL, _ destination: URL) -> Bool {
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: source.resolvingSymlinksInPath().path),
              let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destination.resolvingSymlinksInPath().path),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let destinationDevice = destinationAttributes[.systemNumber] as? NSNumber,
              let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
              let destinationFile = destinationAttributes[.systemFileNumber] as? NSNumber else { return false }
        return sourceDevice == destinationDevice && sourceFile == destinationFile
    }

    /// A saved project can be edited outside the app. Never report a complete export after
    /// silently dropping an orphaned caption or an invalid time interval.
    static func validateCaptions(_ captions: [Caption], clips: [MediaClip]) throws {
        let visible = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard Set(visible.map(\.id)).count == visible.count else {
            throw StudioError.message("文字标识重复，请检查项目后再导出。")
        }
        let clipsByID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for caption in visible {
            guard let clip = clipsByID[caption.clipID] else {
                throw StudioError.message("有一条文字找不到对应素材，请先检查项目。")
            }
            let compactText = caption.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let excerpt = String(compactText.prefix(20)) + (compactText.count > 20 ? "…" : "")
            let context = "“\(clip.name)”里的文字“\(excerpt)”"
            guard caption.text.utf16.count <= 4000 else {
                throw StudioError.message("\(context)超过单条 4000 字的导出上限。请打开这条文字，拆分或精简后再导出；原文字仍完整保留。")
            }
            guard clip.duration.isFinite, clip.duration > 0 else {
                throw StudioError.message("“\(clip.name)”的片段时长无效，请调整片段时长后再导出。")
            }
            guard caption.start.isFinite, caption.duration.isFinite, caption.start >= 0, caption.duration > 0 else {
                throw StudioError.message("\(context)的出现时间无效。请将文字起点设为不小于 0 的秒数、时长设为大于 0 的秒数后再导出。")
            }
            guard caption.start < clip.duration else {
                throw StudioError.message("\(context)的起点已超出片段。请把文字起点移回片段内，或延长片段后再导出。")
            }
        }
    }

    private static func checkCancellation(_ token: UUID) throws {
        try Task.checkCancellation()
        if control.isCancelled(token: token) { throw CancellationError() }
    }

    private static func fileCreatedAt(url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func photoCapturedAt(url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let index = primary >= 0 && primary < CGImageSourceGetCount(source) ? primary : 0
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let candidates: [(String?, String?, String?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
             exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
             exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String),
            (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String,
             exif[kCGImagePropertyExifOffsetTimeDigitized as String] as? String,
             exif[kCGImagePropertyExifSubsecTimeDigitized as String] as? String),
            (tiff[kCGImagePropertyTIFFDateTime as String] as? String,
             exif[kCGImagePropertyExifOffsetTime as String] as? String,
             exif[kCGImagePropertyExifSubsecTime as String] as? String)
        ]
        // Original capture time has priority over digitisation/editing dates. Its own offset,
        // when present, determines the zone; otherwise the Mac's current zone is assumed.
        for (dateString, offset, fraction) in candidates {
            guard let dateString else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
            guard var date = formatter.date(from: dateString + (offset ?? "")) else { continue }
            if let fraction, fraction.allSatisfy(\.isNumber), let subsecond = Double("0." + fraction) {
                date.addTimeInterval(subsecond)
            }
            return date
        }
        return nil
    }

    private static func videoCapturedAt(asset: AVURLAsset) async -> Date? {
        if let metadata = try? await asset.loadMetadata(for: .quickTimeMetadata) {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
            for item in items { if let date = await metadataDate(item) { return date } }
        }
        if let item = try? await asset.load(.creationDate) { return await metadataDate(item) }
        return nil
    }

    private static func metadataDate(_ item: AVMetadataItem) async -> Date? {
        if let date = try? await item.load(.dateValue) { return date }
        guard let value = try? await item.load(.stringValue) else { return nil }
        for fraction in [true, false] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = fraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func decodedImage(url: URL, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // EXIF orientation must be applied, particularly for photos from an iPhone.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                                     kCGImageSourceShouldCacheImmediately: true]
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let index = primary >= 0 && primary < CGImageSourceGetCount(source) ? primary : 0
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func pictureRange(of track: AVAssetTrack) async throws -> CMTimeRange {
        let fullRange = try await track.load(.timeRange)
        // A QuickTime empty edit can make timeRange begin at zero even though no picture
        // exists there. Keep phone timestamps while dropping leading/trailing empty edits.
        let segments = try await track.load(.segments)
        let ranges = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }.filter {
            $0.start.seconds.isFinite && $0.duration.seconds.isFinite && $0.duration.seconds > 0
        }
        guard let first = ranges.map(\.start).min(),
              let last = ranges.map({ CMTimeRangeGetEnd($0) }).max() else { return fullRange }
        return fullRange.intersection(CMTimeRange(start: first, end: last))
    }

    private static func fitTransform(size: CGSize, preferred: CGAffineTransform, canvas: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: size).applying(preferred)
        let scale = min(canvas.width / oriented.width, canvas.height / oriented.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (canvas.width - oriented.width * scale) / 2,
                                           y: (canvas.height - oriented.height * scale) / 2))
    }

    private static func imageMovie(source: URL, destination: URL, size: CGSize,
                                   duration: CMTime, token: UUID) async throws {
        guard let image = decodedImage(url: source, maxDimension: Int(max(size.width, size.height) * 1.5)) else {
            throw StudioError.message("无法解码图片“\(source.lastPathComponent)”。")
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                             AVVideoMaxKeyFrameIntervalKey: 30,
                                             AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: Int(size.width),
                                         kCVPixelBufferHeightKey as String: Int(size.height),
                                         kCVPixelBufferCGImageCompatibilityKey as String: true,
                                         kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw StudioError.message("无法创建照片视频编码器。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError.message("无法开始照片编码。") }
        writer.startSession(atSourceTime: .zero)
        var completed = false
        defer { if !completed { writer.cancelWriting() } }
        var pixelBuffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixelBuffer)
        guard bufferStatus == kCVReturnSuccess, let buffer = pixelBuffer else { throw StudioError.message("照片编码内存不足。") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw StudioError.message("无法绘制照片画面。")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let rect = CGRect(x: (size.width - CGFloat(image.width) * scale) / 2,
                          y: (size.height - CGFloat(image.height) * scale) / 2,
                          width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // One encoded still sample spans this writing session. Final composition renders at 30 fps.
        // Encoding the identical photo 120–900 times only wastes time and storage.
        let frameCount = 1
        for frame in 0..<frameCount {
            try checkCancellation(token)
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !input.isReadyForMoreMediaData {
                try checkCancellation(token)
                guard writer.status == .writing else { throw writer.error ?? StudioError.message("照片编码意外中断。") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw StudioError.message("照片编码超时，请重试。") }
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                throw writer.error ?? StudioError.message("无法写入照片视频帧。")
            }
        }
        writer.endSession(atSourceTime: duration)
        input.markAsFinished()
        await writer.finishWriting()
        try checkCancellation(token)
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("照片编码失败。") }
        completed = true
    }

    private static func addMusic(url: URL, volume: Double, to composition: AVMutableComposition,
                                 duration: CMTime, token: UUID) async throws -> AVMutableAudioMix {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw StudioError.message("找不到所选配乐“\(url.lastPathComponent)”。请重新选择，或关闭配乐后导出。")
        }
        let music = AVURLAsset(url: url)
        guard let source = try await music.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.message("所选配乐没有可读取的音频轨道。")
        }
        let range = try await source.load(.timeRange)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0.05 else { throw StudioError.message("配乐文件时长无效。") }
        var cursor = CMTime.zero
        while cursor < duration {
            try checkCancellation(token)
            let span = CMTimeMinimum(range.duration, CMTimeSubtract(duration, cursor))
            try track.insertTimeRange(CMTimeRange(start: range.start, duration: span), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, span)
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(max(0, min(1, volume)))
        let fade = CMTime(seconds: min(0.6, duration.seconds / 3), preferredTimescale: timescale)
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: .zero, duration: fade))
        parameters.setVolume(gain, at: fade)
        parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: CMTimeSubtract(duration, fade), duration: fade))
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
        return mix
    }

    @MainActor
    private static func captionTool(captions: [Caption], clips: [(MediaClip, CMTime, CMTime)],
                                    canvas: CGSize, totalDuration: Double, token: UUID) async throws -> AVVideoCompositionCoreAnimationTool? {
        let usable = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite && $0.duration.isFinite && $0.duration > 0 }
        guard !usable.isEmpty else { return nil }
        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: canvas)
        let video = CALayer(); video.frame = parent.bounds
        parent.addSublayer(video)
        var layerCount = 0
        // Split at caption changes, so overlap avoidance is identical to the current preview group.
        for (clip, clipStart, clipDuration) in clips {
            let rows = usable.filter { $0.clipID == clip.id && $0.start < clipDuration.seconds && $0.start + $0.duration > 0 }
            guard !rows.isEmpty else { continue }
            let boundaries = Set(rows.flatMap { [max(0, $0.start), min(clipDuration.seconds, $0.start + $0.duration)] }).sorted()
            for index in 0..<max(0, boundaries.count - 1) {
                try checkCancellation(token)
                let start = boundaries[index], end = boundaries[index + 1]
                guard end > start else { continue }
                let active = rows.filter { $0.start < end && $0.start + $0.duration > start }
                let layers = renderedCaptions(active, canvas: canvas)
                for layer in layers {
                    if let id = layer.value(forKey: "captionID") as? String,
                       let caption = active.first(where: { $0.id.uuidString == id }), caption.style == .companion {
                        CompanionStickerRenderer.animate(layer, captionStart: clipStart.seconds + caption.start, totalDuration: totalDuration)
                    }
                    let globalStart = clipStart.seconds + start
                    let globalEnd = clipStart.seconds + end
                    let visibility = CAKeyframeAnimation(keyPath: "opacity")
                    visibility.calculationMode = .discrete
                    visibility.values = [0, 1, 0, 0]
                    visibility.keyTimes = [0, NSNumber(value: max(0, globalStart / totalDuration)),
                                           NSNumber(value: min(1, globalEnd / totalDuration)), 1]
                    visibility.beginTime = AVCoreAnimationBeginTimeAtZero
                    visibility.duration = totalDuration
                    visibility.isRemovedOnCompletion = false
                    visibility.fillMode = .both
                    layer.opacity = 0
                    layer.add(visibility, forKey: "clip-caption")
                    parent.addSublayer(layer)
                    layerCount += 1
                }
                // Long projects must not monopolize the UI actor while drawing caption cards.
                await Task.yield()
            }
        }
        guard layerCount > 0 else { return nil }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    /// The preview and exporter both pass exactly the captions visible at the current frame.
    @MainActor
    static func renderedCaptions(_ captions: [Caption], canvas: CGSize, localTime: Double? = nil) -> [CALayer] {
        let rank: [CaptionStyle: Int] = [.subtitle: 0, .sticker: 1, .note: 2, .companion: 3]
        let ordered = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.style != $1.style { return rank[$0.style, default: 0] < rank[$1.style, default: 0] }
            return $0.id.uuidString < $1.id.uuidString
        }
        let gap = min(canvas.width, canvas.height) * 0.018
        var occupied: [CGRect] = []
        let layers = ordered.map { caption -> CALayer in
            let layer = caption.style == .companion
                ? CompanionStickerRenderer.layer(for: caption, canvas: canvas, localTime: localTime)
                : renderedCaption(caption, canvas: canvas)
            layer.setValue(caption.id.uuidString, forKey: "captionID")
            layer.setValue(caption.clipID.uuidString, forKey: "clipID")
            var frame = layer.frame
            // Scan from bottom to top once. An unbounded collision loop can spin forever
            // when floating-point rounding leaves the expanded rectangles touching.
            for obstacle in occupied.sorted(by: { $0.minY < $1.minY }) {
                if obstacle.intersects(frame.insetBy(dx: -gap, dy: -gap)) {
                    frame.origin.y = max(frame.minY + 1, obstacle.maxY + gap + 1)
                }
            }
            layer.frame = frame; occupied.append(frame)
            return layer
        }
        if let top = occupied.map(\.maxY).max(), top > canvas.height * 0.93,
           let bottom = occupied.map(\.minY).min() {
            // Keep every word inside the canvas when several long cards coincide.
            let scale = min(1, canvas.height * 0.84 / max(1, top - bottom))
            for (layer, caption) in zip(layers, ordered) {
                let old = layer.frame
                let width = old.width * scale
                let x: CGFloat
                switch caption.style {
                case .subtitle: x = (canvas.width - width) / 2
                case .sticker: x = canvas.width * 0.925 - width
                case .note, .companion: x = canvas.width * 0.075
                }
                let originY = canvas.height * 0.07 + (old.minY - bottom) * scale
                if caption.style == .companion {
                    // Unlike a flat caption raster, this layer has a character and
                    // bubble as separate children. Scale their shared coordinate space.
                    layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                    layer.position = CGPoint(x: x + width / 2, y: originY + old.height * scale / 2)
                } else {
                    layer.frame = CGRect(x: x, y: originY, width: width, height: old.height * scale)
                }
                layer.name = "caption-compact"
            }
        }
        return layers
    }

    @MainActor private static let captionCache: NSCache<NSString, CaptionRaster> = {
        let cache = NSCache<NSString, CaptionRaster>(); cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func renderedCaption(_ caption: Caption, canvas: CGSize) -> CALayer {
        if caption.style == .companion { return CompanionStickerRenderer.layer(for: caption, canvas: canvas, localTime: nil) }
        let key = "\(canvas.width)x\(canvas.height)|\(caption.style.rawValue)|\(caption.text)" as NSString
        if let cached = captionCache.object(forKey: key) { return captionLayer(raster: cached) }
        let base = min(canvas.width, canvas.height) / 1080
        let initialFontSize = (caption.style == .subtitle ? 43.0 : caption.style == .sticker ? 44.0 : 40.0) * base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = caption.style == .subtitle ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        let inset = CGSize(width: 30 * base, height: 21 * base)
        let maxWidth = canvas.width * (caption.style == .subtitle ? 0.82 : caption.style == .sticker ? 0.60 : 0.62)
        let foreground: NSColor = caption.style == .sticker
            ? NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.18, alpha: 1) : .white
        var fontSize = initialFontSize
        var text: NSAttributedString!
        var measured = NSRect.zero
        repeat {
            paragraph.lineSpacing = fontSize * 0.22
            let font = NSFont.systemFont(ofSize: fontSize, weight: caption.style == .note ? .regular : .semibold)
            let displayText = caption.text.utf16.count > 4000 ? String(caption.text.prefix(4000)) + "\n文字过长，请拆成几句。" : caption.text
            text = NSAttributedString(string: displayText, attributes: [
                .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
            ])
            measured = text.boundingRect(with: NSSize(width: maxWidth - inset.width * 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
            if measured.height + inset.height * 2 <= canvas.height * 0.72 || fontSize <= base { break }
            fontSize *= 0.9
        } while true
        let imageSize = NSSize(width: ceil(min(maxWidth, max(fontSize * 3, measured.width + inset.width * 2))),
                               height: ceil(min(canvas.height * 0.72, max(fontSize * 1.5, measured.height + inset.height * 2))))
        // Rendering once with AppKit gives correct Chinese shaping and line wrapping at export resolution.
        let image = NSImage(size: imageSize)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: imageSize)
        switch caption.style {
        case .subtitle:
            NSColor.black.withAlphaComponent(0.64).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 13 * base, yRadius: 13 * base).fill()
        case .sticker:
            NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.94, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 24 * base, yRadius: 24 * base).fill()
        case .note:
            NSColor(calibratedRed: 0.95, green: 0.47, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 5 * base, y: inset.height, width: 4 * base,
                                           height: imageSize.height - inset.height * 2),
                         xRadius: 2 * base, yRadius: 2 * base).fill()
        case .companion: break // Handled by the shared companion renderer above.
        }
        let shadow = NSShadow()
        if caption.style == .note {
            shadow.shadowColor = .black; shadow.shadowBlurRadius = 6 * base
            shadow.shadowOffset = NSSize(width: 0, height: -2 * base); shadow.set()
        }
        text.draw(with: bounds.insetBy(dx: inset.width, dy: inset.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        var imageRect = NSRect(origin: .zero, size: imageSize)
        let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
        let x: CGFloat
        let y: CGFloat
        switch caption.style {
        case .subtitle:
            x = (canvas.width - imageSize.width) / 2; y = canvas.height * 0.07
        case .sticker:
            x = canvas.width - imageSize.width - canvas.width * 0.075; y = canvas.height * 0.12
        case .note, .companion:
            x = canvas.width * 0.075; y = canvas.height * 0.12
        }
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: imageSize)
        let raster = CaptionRaster(image: cgImage, frame: frame, compact: fontSize < initialFontSize * 0.6)
        if let cgImage { captionCache.setObject(raster, forKey: key, cost: cgImage.bytesPerRow * cgImage.height) }
        return captionLayer(raster: raster)
    }

    @MainActor private static func captionLayer(raster: CaptionRaster) -> CALayer {
        let layer = CALayer()
        layer.contents = raster.image
        layer.contentsGravity = .resize
        layer.frame = raster.frame
        layer.name = raster.compact ? "caption-compact" : "caption"
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = max(1, raster.frame.width / 100)
        layer.shadowOffset = CGSize(width: 0, height: -3)
        return layer
    }

}

private final class CaptionRaster {
    let image: CGImage?
    let frame: CGRect
    let compact: Bool
    init(image: CGImage?, frame: CGRect, compact: Bool) { self.image = image; self.frame = frame; self.compact = compact }
}

/// Cancellation is synchronous because the UI's Cancel button must stop an encoder immediately.
private final class ExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?
    private var cancelled = false
    private var exporter: AVAssetExportSession?
    func begin() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw StudioError.message("另一个视频正在导出，请等待完成或取消。") }
        let id = UUID(); active = id; cancelled = false; exporter = nil; return id
    }
    func set(exporter: AVAssetExportSession, token: UUID) {
        lock.lock()
        let shouldCancel = active != token || cancelled
        if active == token { self.exporter = exporter }
        lock.unlock()
        if shouldCancel { exporter.cancelExport() }
    }
    func cancel(token: UUID? = nil) {
        lock.lock()
        guard active != nil, token == nil || token == active else { lock.unlock(); return }
        cancelled = true; let session = exporter
        lock.unlock()
        session?.cancelExport()
    }
    func isCancelled(token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active != token || cancelled
    }
    func finish(token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active == token { active = nil; exporter = nil; cancelled = false }
    }
}
