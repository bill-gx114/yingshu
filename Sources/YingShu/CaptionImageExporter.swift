import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Exports only pictures that carry visible captions. It never modifies the media originals.
enum CaptionImageExporter {
    private struct Frame {
        var clip: MediaClip
        var start: Double
        var end: Double
        var captions: [Caption]
        var keyTime: Double { start + (end - start) / 2 }
    }

    static func export(clips: [MediaClip], captions: [Caption], format: VideoFormat, to directory: URL,
                       companionProfile: CompanionProfile = .classic, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        try Task.checkCancellation()
        guard directory.isFileURL, (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw StudioError.message("请选择一个已存在的本地文件夹来保存图片。")
        }
        let frames = try plan(clips: clips, captions: captions)
        guard !frames.isEmpty else { throw StudioError.message("还没有可导出的文字。请先留下感想或添加字幕/贴纸。") }
        // Validate every required source before creating a staging directory or rendering.
        // Uncaptioned clips intentionally do not need their original for a picture export.
        for frame in frames {
            guard frame.clip.url.isFileURL, FileManager.default.isReadableFile(atPath: frame.clip.url.path) else {
                throw StudioError.message("找不到素材“\(frame.clip.name)”（\(frame.clip.url.lastPathComponent)），请重新关联原文件。整批图片尚未保存。")
            }
        }
        if frames.contains(where: { $0.captions.contains(where: { $0.style == .companion }) }) {
            try await CompanionStickerRenderer.prepare(companionProfile)
        }
        try Task.checkCancellation()
        let identifier = UUID().uuidString
        let staging = directory.appendingPathComponent(".YingShu-images-\(identifier)", isDirectory: true)
        let completed = directory.appendingPathComponent("字幕图片-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        progress(0)
        var imageCache: [URL: CGImage] = [:]
        var videoGenerators: [URL: AVAssetImageGenerator] = [:]
        var names: [String] = []
        var indexRows: [[String]] = [["顺序", "图片文件", "原素材", "片段内开始秒", "片段内结束秒", "截图位置秒", "文字"]]
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let source: CGImage
            var sourceTime = frame.keyTime
            if frame.clip.kind == .image {
                if let cached = imageCache[frame.clip.url] { source = cached }
                else {
                    source = try photo(url: frame.clip.url, size: format.size)
                    // Avoid retaining an entire album: adjacent caption groups use one photo.
                    imageCache = [frame.clip.url: source]
                }
            } else {
                let generator: AVAssetImageGenerator
                if let cached = videoGenerators[frame.clip.url] { generator = cached }
                else {
                    generator = AVAssetImageGenerator(asset: AVURLAsset(url: frame.clip.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: format.size.width * 1.5, height: format.size.height * 1.5)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
                    videoGenerators = [frame.clip.url: generator]
                }
                let time = frame.clip.trimStart + frame.keyTime
                do {
                    let generated = try await withTaskCancellationHandler {
                        try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    } onCancel: { generator.cancelAllCGImageGeneration() }
                    source = generated.image
                    sourceTime = generated.actualTime.seconds
                } catch {
                    // AVFoundation may translate cancellation into an encoder error.
                    try Task.checkCancellation()
                    throw StudioError.message("无法截取“\(frame.clip.name)”（\(frame.clip.url.lastPathComponent)）在 \(seconds(time)) 秒的画面：\(error.localizedDescription) 整批图片尚未保存。")
                }
            }
            try Task.checkCancellation()
            let overlay = try await captionOverlay(captions: frame.captions, size: format.size, localTime: frame.keyTime, companionProfile: companionProfile)
            let output = try compose(source: source, overlay: overlay, size: format.size)
            let name = String(format: "%05d_", index + 1) + safeName(frame.clip.name) + ".png"
            let url = staging.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw StudioError.message("无法创建图片文件，请检查文件夹权限。")
            }
            CGImageDestinationAddImage(destination, output, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw StudioError.message("图片写入失败，请检查磁盘空间。整批图片尚未保存。")
            }
            names.append(name)
            indexRows.append([String(index + 1), name, frame.clip.url.lastPathComponent,
                              seconds(frame.start), seconds(frame.end), seconds(sourceTime),
                              frame.captions.map(\.text).joined(separator: "\n")])
            progress(Double(index + 1) / Double(frames.count + 1))
            await Task.yield()
        }
        try Task.checkCancellation()
        let csv = "\u{FEFF}" + indexRows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        try Data(csv.utf8).write(to: staging.appendingPathComponent("index.csv"), options: .atomic)
        let explanation = """
        字幕图片导出

        共 \(names.count) 张 PNG，按照文件名前的数字顺序导入剪映或抖音即可，再选择平台音乐。
        图片中的文字已经固定在画面上，无需重新逐张添加字幕。

        同一段素材中的文字分时出现或互相重叠时，会按每个可见组合导出不同图片，避免漏掉感想。
        index.csv 记录每张图片对应的素材、时间范围和文字，可作为设置图片时长的参考。
        视频和实况照片使用相应时刻的截图，PNG 本身不会播放动态，也不包含声音或音乐。
        画布为 \(Int(format.size.width)) × \(Int(format.size.height))；素材按比例完整显示，空余部分为黑色。
        原照片和原视频没有被修改。
        """
        try Data(explanation.utf8).write(to: staging.appendingPathComponent("导出说明.txt"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: completed)
        committed = true
        progress(1)
        return names.map { completed.appendingPathComponent($0) }
    }

    private static func plan(clips: [MediaClip], captions: [Caption]) throws -> [Frame] {
        guard Set(clips.map(\.id)).count == clips.count else { throw StudioError.message("素材标识重复，无法确定文字对应的图片。") }
        try MediaEngine.validateCaptions(captions, clips: clips)
        let visible = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [Frame] = []
        for clip in clips {
            let rows = visible.filter { $0.clipID == clip.id }
            guard !rows.isEmpty else { continue }
            guard clip.duration.isFinite, clip.duration > 0, clip.trimStart.isFinite, clip.trimStart >= 0 else {
                throw StudioError.message("“\(clip.name)”的素材时间无效。")
            }
            let boundaries = Set(rows.flatMap { [max(0, $0.start), min(clip.duration, $0.start + $0.duration)] }).sorted()
            for pair in zip(boundaries, boundaries.dropFirst()) {
                let start = pair.0, end = pair.1
                guard end > start else { continue }
                let middle = start + (end - start) / 2
                let active = rows.filter { $0.start <= middle && $0.start + $0.duration > middle }
                if !active.isEmpty { result.append(Frame(clip: clip, start: start, end: end, captions: active)) }
            }
        }
        return result
    }

    private static func photo(url: URL, size: CGSize) throws -> CGImage {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw StudioError.message("无法读取原照片“\(url.lastPathComponent)”，请确认素材仍在原位置并允许读取。整批图片尚未保存。")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw StudioError.message("原照片“\(url.lastPathComponent)”无法解码，文件可能已损坏或格式不受当前 macOS 支持。请从原片重新导出 JPEG/HEIC 后重试。整批图片尚未保存。")
        }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let index = primary >= 0 && primary < CGImageSourceGetCount(source) ? primary : 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 1.5),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw StudioError.message("原照片“\(url.lastPathComponent)”无法解码，文件可能已损坏或格式不受当前 macOS 支持。请从原片重新导出 JPEG/HEIC 后重试。整批图片尚未保存。")
        }
        return image
    }

    @MainActor private static func captionOverlay(captions: [Caption], size: CGSize, localTime: Double, companionProfile: CompanionProfile) throws -> CGImage {
        try Task.checkCancellation()
        guard let context = bitmap(size: size) else { throw StudioError.message("无法分配字幕图片内存。") }
        let root = CALayer(); root.frame = CGRect(origin: .zero, size: size)
        for layer in MediaEngine.renderedCaptions(captions, canvas: size, localTime: localTime, companionProfile: companionProfile) {
            if let id = layer.value(forKey: "captionID") as? String,
               captions.contains(where: { $0.id.uuidString == id && $0.style == .companion }) {
                try CompanionStickerRenderer.validateExportLayer(layer)
            }
            root.addSublayer(layer)
        }
        root.layoutIfNeeded(); root.render(in: context)
        guard let image = context.makeImage() else { throw StudioError.message("无法生成字幕画面。") }
        return image
    }

    private static func compose(source: CGImage, overlay: CGImage, size: CGSize) throws -> CGImage {
        guard let context = bitmap(size: size) else { throw StudioError.message("无法分配图片导出内存。") }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        let scale = min(size.width / CGFloat(source.width), size.height / CGFloat(source.height))
        let frame = CGRect(x: (size.width - CGFloat(source.width) * scale) / 2,
                           y: (size.height - CGFloat(source.height) * scale) / 2,
                           width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.interpolationQuality = .high
        context.draw(source, in: frame)
        context.draw(overlay, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw StudioError.message("无法生成完整图片。") }
        return result
    }

    private static func bitmap(size: CGSize) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func safeName(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) { return "_" }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return scalars.isEmpty ? "画面" : String(scalars.prefix(40))
    }

    private static func csvField(_ value: String) -> String {
        var safe = value
        if let first = safe.first, "=+-@".contains(first) { safe = "'" + safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
