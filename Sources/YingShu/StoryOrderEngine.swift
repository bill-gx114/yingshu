import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Produces an ordering proposal. Clip identity, source windows, and all other fields are untouched.
enum StoryOrderEngine {
    private struct Item {
        var clip: MediaClip
        var inputIndex: Int
        var time: Date?
        var importKey: Int { clip.importOrder ?? inputIndex }
    }
    private struct Pixels {
        var gray: [Float]
        var quality: Double
        var complexity: Double
        var balance: Double
    }
    private struct Visual {
        var feature: VNFeaturePrintObservation
        var quality: Double
        var complexity: Double
        var composition: Double
        var faceArea: Double
        var motion: Double
        var landscape: Double
    }
    private static let maximumModelClips = 180
    private static let maximumGroupClips = 8

    static func arrange(clips: [MediaClip], mode: ClipOrderMode,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StoryOrderResult {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try await propose(clips: clips, mode: mode, progress: progress)
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await work.value
                try Task.checkCancellation()
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { work.cancel() }
    }

    private static func propose(clips: [MediaClip], mode: ClipOrderMode,
                                progress: @escaping @Sendable (Double, String) -> Void) async throws -> StoryOrderResult {
        try Task.checkCancellation()
        guard Set(clips.map(\.id)).count == clips.count else { throw StudioError.message("素材标识重复，无法稳定排序。") }
        guard !clips.isEmpty else { return StoryOrderResult(clips: [], summary: "请先加入素材。") }
        let items = clips.enumerated().map { index, clip in
            Item(clip: clip, inputIndex: index, time: valid(clip.capturedAt) ?? valid(clip.fileCreatedAt))
        }
        switch mode {
        case .manual:
            progress(1, "保留当前手动顺序。")
            return StoryOrderResult(clips: clips, summary: "保留当前手动顺序。")
        case .imported:
            let ordered = items.sorted(by: stableImport)
            progress(1, "已恢复导入顺序。")
            return StoryOrderResult(clips: ordered.map(\.clip), summary: "已按记录的导入顺序排列；缺少记录的素材保留原有先后。")
        case .filename:
            let ordered = items.sorted { left, right in
                let leftName = (left.clip.livePhotoStillURL ?? left.clip.url).lastPathComponent
                let rightName = (right.clip.livePhotoStillURL ?? right.clip.url).lastPathComponent
                let comparison = leftName.compare(rightName,
                    options: [.numeric, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return comparison == .orderedSame ? stableImport(left, right) : comparison == .orderedAscending
            }
            progress(1, "已按文件名排列。")
            return StoryOrderResult(clips: ordered.map(\.clip), summary: "已按原文件名排列，同名素材保留导入先后。")
        case .chronological, .story: break
        }
        let chronological = items.sorted(by: earlier)
        let metadataNote = timeSummary(clips, story: mode == .story)
        if mode == .chronological {
            progress(1, "已按拍摄时间排列。")
            return StoryOrderResult(clips: chronological.map(\.clip), summary: "已按拍摄时间排列。\(metadataNote)")
        }

        progress(0.03, "正在结合时间与画面组织故事…")
        var visuals: [UUID: Visual] = [:]
        var failed = 0
        let analysisCount = min(maximumModelClips, chronological.count)
        for (index, item) in chronological.prefix(analysisCount).enumerated() {
            try Task.checkCancellation()
            progress(0.05 + 0.78 * Double(index) / Double(max(1, analysisCount)), "正在看画面 \(index + 1) / \(analysisCount)…")
            do { visuals[item.clip.id] = try await analyze(item.clip) }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                failed += 1
            }
        }
        try Task.checkCancellation()
        let groups = makeGroups(chronological, visuals: visuals)
        var ordered: [Item] = []
        var adjustedGroups = 0
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            progress(0.85 + 0.14 * Double(index) / Double(max(1, groups.count)), "正在安排每组的开场、变化与收尾…")
            // A missing/unanalyzed item is a reason to preserve this group's chronological order.
            let proposal = group.allSatisfy { visuals[$0.clip.id] != nil } ? try narrative(group, visuals: visuals) : group
            if proposal.map(\.clip.id) != group.map(\.clip.id) { adjustedGroups += 1 }
            ordered.append(contentsOf: proposal)
        }
        let moved = zip(chronological, ordered).filter { $0.clip.id != $1.clip.id }.count
        var summary = "已结合时间与本机画面分析，分成 \(groups.count) 组故事，组内调整 \(moved) 段。"
        if adjustedGroups == 0 { summary = "画面关系与时间顺序相符，保留各组原有先后。" }
        summary += " 同组参考人物、相似画面、清晰度与动静安排开场和收尾，保留日期顺序。\(metadataNote)"
        if clips.count > maximumModelClips { summary += " 本次画面模型最多分析前 \(maximumModelClips) 段，其余组沿用时间顺序。" }
        if failed > 0 { summary += " \(failed) 段画面暂未完成分析，其所在组沿用时间顺序。" }
        progress(1, "故事顺序已就绪。")
        return StoryOrderResult(clips: ordered.map(\.clip), summary: summary)
    }

    private static func valid(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }
    private static func stableImport(_ left: Item, _ right: Item) -> Bool {
        if left.importKey != right.importKey { return left.importKey < right.importKey }
        return left.inputIndex < right.inputIndex
    }
    private static func earlier(_ left: Item, _ right: Item) -> Bool {
        switch (left.time, right.time) {
        case let (a?, b?): return a == b ? stableImport(left, right) : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return stableImport(left, right)
        }
    }
    private static func timeSummary(_ clips: [MediaClip], story: Bool) -> String {
        let fallback = clips.filter { valid($0.capturedAt) == nil && valid($0.fileCreatedAt) != nil }.count
        let unknown = clips.filter { valid($0.capturedAt) == nil && valid($0.fileCreatedAt) == nil }.count
        var text = ""
        if fallback > 0 { text += " \(fallback) 段缺少拍摄时间，采用文件创建时间作参考。" }
        if unknown > 0 {
            text += story ? " \(unknown) 段没有可用时间，单列在最后，参考画面关系组织组内先后。"
                : " \(unknown) 段没有可用时间，放在最后并保留导入先后。"
        }
        return text
    }

    private static func makeGroups(_ items: [Item], visuals: [UUID: Visual]) -> [[Item]] {
        var groups: [[Item]] = []
        let calendar = Calendar.current
        for item in items {
            guard let previous = groups.last?.last, let first = groups.last?.first else { groups.append([item]); continue }
            var boundary = (groups.last?.count ?? 0) >= maximumGroupClips
            switch (previous.time, item.time, first.time) {
            case let (a?, b?, beginning?):
                let gap = b.timeIntervalSince(a)
                boundary = boundary || !calendar.isDate(a, inSameDayAs: b) || gap > 30 * 60 || b.timeIntervalSince(beginning) > 45 * 60
                // The feature model can support a scene boundary, but only together with a
                // meaningful time gap; a portrait and a view taken together stay in one event.
                if gap > 4 * 60, let va = visuals[previous.clip.id], let vb = visuals[item.clip.id], distance(va, vb) > 16 { boundary = true }
            case (nil, nil, nil): break
            default: boundary = true
            }
            if boundary { groups.append([item]) } else { groups[groups.count - 1].append(item) }
        }
        return groups
    }

    private static func narrative(_ group: [Item], visuals: [UUID: Visual]) throws -> [Item] {
        guard group.count > 1 else { return group }
        let firstTime = group.compactMap(\.time).min()?.timeIntervalSince1970
        let lastTime = group.compactMap(\.time).max()?.timeIntervalSince1970
        let span = max(1, (lastTime ?? 0) - (firstTime ?? 0))
        func position(_ item: Item) -> Double {
            guard let value = item.time?.timeIntervalSince1970, let firstTime else { return 0 }
            return (value - firstTime) / span
        }
        func opener(_ item: Item) -> Double {
            let v = visuals[item.clip.id]!
            let environment = max(0, 1 - v.faceArea * 5)
            return 0.55 * v.quality + 0.15 * v.composition + 0.15 * environment + 0.10 * v.landscape - 0.08 * v.motion - 0.18 * position(item)
        }
        func closer(_ item: Item) -> Double {
            let v = visuals[item.clip.id]!
            let calm = max(0, 1 - v.motion - v.complexity * 0.45)
            return v.quality * (0.6 + 0.4 * calm) + v.composition * 0.12 + position(item) * 0.10
        }
        func best(_ candidates: [Item], score: (Item) -> Double) -> Item {
            candidates.dropFirst().reduce(candidates[0]) { selected, item in
                let difference = score(item) - score(selected)
                if abs(difference) < 0.000_001 { return stableImport(item, selected) ? item : selected }
                return difference > 0 ? item : selected
            }
        }
        let opening = best(group, score: opener)
        var remaining = group.filter { $0.clip.id != opening.clip.id }
        let ending: Item? = group.count >= 4 ? best(remaining, score: closer) : nil
        if let ending { remaining.removeAll { $0.clip.id == ending.clip.id } }
        var ordered = [opening]
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let previous = ordered.last!
            let previousVisual = visuals[previous.clip.id]!
            let chosen = best(remaining) { candidate in
                let v = visuals[candidate.clip.id]!
                let separation = distance(previousVisual, v)
                let repeated = max(0, 1 - separation / 7)
                let timeDistance = abs(position(candidate) - position(previous))
                let variedMedia = candidate.clip.kind != previous.clip.kind && separation < 15 ? 0.12 : 0
                return v.quality * 0.28 - repeated * 0.72 - timeDistance * 0.18 + variedMedia + v.motion * 0.07
            }
            ordered.append(chosen)
            remaining.removeAll { $0.clip.id == chosen.clip.id }
        }
        if let ending { ordered.append(ending) }
        // Identical views are interchangeable to the model, but their identities are not.
        // Keep their chronological/import tie order in the chosen slots. Otherwise an item
        // reserved as the closer could swap with its twin on every repeated invocation.
        var handled = Set<UUID>()
        for item in group where !handled.contains(item.clip.id) {
            let twins = group.filter {
                $0.clip.kind == item.clip.kind && !handled.contains($0.clip.id)
                    && distance(visuals[item.clip.id]!, visuals[$0.clip.id]!) < 0.015
            }
            let identities = Set(twins.map(\.clip.id))
            handled.formUnion(identities)
            if twins.count > 1 {
                let slots = ordered.indices.filter { identities.contains(ordered[$0].clip.id) }
                for (slot, twin) in zip(slots, twins) { ordered[slot] = twin }
            }
        }
        return ordered
    }

    /// Revision 1 distances are used consistently; revision 2 has a different numeric scale.
    private static func distance(_ left: Visual, _ right: Visual) -> Double {
        var value: Float = .greatestFiniteMagnitude
        guard (try? left.feature.computeDistance(&value, to: right.feature)) != nil, value.isFinite else { return 20 }
        return Double(value)
    }

    private static func analyze(_ clip: MediaClip) async throws -> Visual {
        try Task.checkCancellation()
        let picture: CGImage
        var motion = 0.0
        if clip.kind == .image {
            guard let value = thumbnail(clip.url) else { throw StudioError.message("无法读取画面。") }
            picture = value
        } else {
            guard clip.duration.isFinite, clip.duration > 0, clip.trimStart.isFinite, clip.trimStart >= 0 else { throw StudioError.message("视频时间无效。") }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.06, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.06, preferredTimescale: 600)
            let start = clip.trimStart + clip.duration * 0.35
            let middle = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: start, preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            // A Live Photo remains one clip. Its still companion can describe the subject while
            // actual movie samples measure movement; the companion is never inserted separately.
            picture = clip.livePhotoStillURL.flatMap(thumbnail) ?? middle.image
            let after = min(start + 0.35, clip.trimStart + clip.duration - 1.0 / 30)
            if after > start + 0.05 {
                let neighbor = try await withTaskCancellationHandler {
                    try await generator.image(at: CMTime(seconds: after, preferredTimescale: 600))
                } onCancel: { generator.cancelAllCGImageGeneration() }
                let a = pixels(middle.image).gray, b = pixels(neighbor.image).gray
                let change = zip(a, b).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(max(1, a.count))
                motion = min(1, change / 0.16)
            }
        }
        try Task.checkCancellation()
        let faces = VNDetectFaceRectanglesRequest()
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.revision = VNGenerateImageFeaturePrintRequestRevision1
        let requests: [VNRequest] = [faces, feature]
        for request in requests {
            if let stages = try? request.supportedComputeStageDevices {
                for (stage, devices) in stages {
                    if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu, for: stage) }
                }
            }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: picture, options: [:]).perform(requests)
            try Task.checkCancellation()
        } onCancel: { requests.forEach { $0.cancel() } }
        guard let embedding = feature.results?.first else { throw StudioError.message("画面模型没有返回特征。") }
        let details = pixels(picture)
        let faceArea = (faces.results ?? []).reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        return Visual(feature: embedding, quality: details.quality, complexity: details.complexity,
                      composition: details.balance, faceArea: faceArea, motion: motion,
                      landscape: max(0, min(1, (Double(picture.width) / Double(max(1, picture.height)) - 1) / 0.8)))
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let index = primary < CGImageSourceGetCount(source) ? primary : 0
        return CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
    }

    private static func pixels(_ image: CGImage) -> Pixels {
        let side = 96
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var gray = [Float](repeating: 0, count: side * side)
        var sum = 0.0, squares = 0.0, clipped = 0.0
        for i in gray.indices {
            let start = i * 4
            let value = (Double(rgba[start]) * 0.2126 + Double(rgba[start + 1]) * 0.7152 + Double(rgba[start + 2]) * 0.0722) / 255
            gray[i] = Float(value); sum += value; squares += value * value
            if value < 0.025 || value > 0.975 { clipped += 1 }
        }
        let count = Double(gray.count), mean = sum / count
        let contrast = min(1, sqrt(max(0, squares / count - mean * mean)) / 0.23)
        var laplacian = 0.0, edges = 0.0, weightedX = 0.0, weightedY = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let edge = Double(abs(gray[i + 1] - gray[i - 1]) + abs(gray[i + side] - gray[i - side]))
                let lap = Double(gray[i - 1] + gray[i + 1] + gray[i - side] + gray[i + side] - gray[i] * 4)
                laplacian += lap * lap; edges += edge
                weightedX += Double(x) * edge; weightedY += Double(y) * edge
            }
        }
        let sharpness = min(1, sqrt(laplacian / count) / 0.16)
        let density = min(1, edges / count / 0.17)
        let balance = edges > 0.001 ? max(0, 1 - abs(weightedX / edges / Double(side) - 0.5) - abs(weightedY / edges / Double(side) - 0.5)) : 0.25
        return Pixels(gray: gray, quality: 0.5 * sharpness + 0.3 * contrast + 0.2 * (1 - clipped / count),
                      complexity: 0.5 * density + 0.5 * contrast, balance: balance)
    }
}
