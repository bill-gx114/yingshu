import Accelerate
import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Local content analysis and onset-based editing. The result is a proposal; originals are untouched.
enum AutoEditEngine {
    struct BeatAnalysis {
        var times: [Double]
        var bpm: Double?
        var confidence: Double
        var analyzedDuration: Double
        var fileDuration: Double
    }

    private struct Pixels {
        var luminance: [Float]
        var quality: Double
        var complexity: Double
        var balance: Double
    }
    private struct Frame {
        var time: Double
        var importance: Double
        var feature: VNFeaturePrintObservation?
        var pixels: Pixels
        var motion: Double = 0
    }
    private struct Content {
        var score: Double
        var bestTime: Double
        var feature: VNFeaturePrintObservation?
        var duplicate: Double = 0
        var motion: Double = 0
    }

    static func plan(clips: [MediaClip], captions: [Caption], musicURL: URL?,
                     progress: @escaping @Sendable (Double, String) -> Void) async throws -> AutoEditResult {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try await buildPlan(clips: clips, captions: captions, musicURL: musicURL, progress: progress)
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

    private static func buildPlan(clips: [MediaClip], captions: [Caption], musicURL: URL?,
                                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> AutoEditResult {
        try Task.checkCancellation()
        guard !clips.isEmpty else {
            return AutoEditResult(clips: [], captions: captions, beatTimes: [], estimatedBPM: nil, summary: "请先加入照片或视频。")
        }
        guard Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.sourceDuration.isFinite && $0.sourceDuration > 0 && $0.trimStart.isFinite && $0.trimStart >= 0 }),
              captions.allSatisfy({ c in c.start.isFinite && c.start >= 0 && c.duration.isFinite && c.duration > 0 && clips.contains { $0.id == c.clipID } }) else {
            throw StudioError.message("素材或文字的时间信息无效，无法自动编排。")
        }
        var content: [Content] = []
        var recentFeatures: [VNFeaturePrintObservation] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            progress(0.68 * Double(index) / Double(clips.count), "正在判断画面内容 \(index + 1) / \(clips.count)…")
            var analysis = try await analyze(clip: clip, mayChooseHighlight: !captions.contains { $0.clipID == clip.id })
            if let feature = analysis.feature {
                // Compare actual Vision embeddings, not filenames or import order.
                for previous in recentFeatures {
                    try Task.checkCancellation()
                    var distance: Float = .greatestFiniteMagnitude
                    if (try? feature.computeDistance(&distance, to: previous)) != nil {
                        analysis.duplicate = max(analysis.duplicate, max(0, 1 - Double(distance) / 5))
                    }
                }
                recentFeatures.append(feature)
                if recentFeatures.count > 12 { recentFeatures.removeFirst() }
            }
            analysis.score *= 1 - 0.52 * analysis.duplicate
            content.append(analysis)
        }

        var preferred: [Double] = []
        var minimums: [Double] = []
        var maximums: [Double] = []
        for (index, clip) in clips.enumerated() {
            if clip.timingLocked == true {
                preferred.append(clip.duration)
                minimums.append(clip.duration)
                maximums.append(clip.duration)
                continue
            }
            let text = captions.filter { $0.clipID == clip.id }
            let readingEnd = text.map { $0.start + max($0.duration, readingDuration($0.text)) }.max() ?? 0
            let imageGroups = captionGroups(indices: captions.indices.filter { captions[$0].clipID == clip.id }, captions: captions)
            let groupedReading = imageGroups.reduce(0.0) { $0 + groupReading($1, captions: captions) } + Double(max(0, imageGroups.count - 1)) * 0.12
            let required = clip.kind == .image ? max(readingEnd, groupedReading) : readingEnd
            let ordinary = clip.kind == .image
                ? 1.5 + content[index].score * 5.1
                : 2.1 + content[index].score * 4.8 + content[index].motion * 0.6
            let sourceRoom = max(1.0 / 30, clip.sourceDuration - (text.isEmpty ? (clip.sourceStart ?? 0) : clip.trimStart))
            let upper = clip.kind == .image ? max(7, required + (text.isEmpty ? 0 : 1.2)) : sourceRoom
            let lower = min(upper, max(clip.kind == .image ? 1.5 : min(1.5, sourceRoom), required))
            preferred.append(min(upper, max(lower, min(clip.kind == .image ? 7 : 7.5, ordinary))))
            minimums.append(lower)
            maximums.append(upper)
        }

        var beats = BeatAnalysis(times: [], bpm: nil, confidence: 0, analyzedDuration: 0, fileDuration: 0)
        var musicNote = "未选择配乐，已按画面内容安排节奏。"
        if let musicURL {
            progress(0.70, "正在听取配乐的真实节奏…")
            do {
                beats = try await detectBeats(url: musicURL, maximumDuration: min(180, max(24, preferred.reduce(0, +) + 10)))
                if let bpm = beats.bpm {
                    musicNote = "配乐约 \(Int(bpm.rounded())) BPM，节拍置信 \(Int((beats.confidence * 100).rounded()))%。"
                } else { musicNote = "配乐未检测到稳定节拍，已按画面内容平缓编排。" }
            } catch is CancellationError { throw CancellationError() }
            catch { musicNote = "配乐暂时无法分析，已按画面内容安排节奏。" }
        }
        try Task.checkCancellation()
        var beatTimes = beats.times
        let estimatedLength = preferred.reduce(0, +) + Double(clips.count)
        // A short music file is looped by MediaEngine. Repeat only measured attacks from a
        // fully analyzed file; never extend a guessed BPM grid into unmeasured audio.
        if beats.bpm != nil, beats.fileDuration > 0,
           beats.analyzedDuration >= beats.fileDuration - 0.05, estimatedLength > beats.fileDuration {
            let cycles = min(1000, Int(ceil(estimatedLength / beats.fileDuration)))
            if cycles > 1 {
                beatTimes = (0..<cycles).flatMap { cycle in beats.times.map { $0 + Double(cycle) * beats.fileDuration } }
            }
        }

        progress(0.90, "正在分配停留时长与换镜点…")
        var edited = clips
        var adjustedCaptions = captions
        var cursor = 0.0
        var longer = 0, shorter = 0, highlights = 0, locked = 0, readingWarnings = 0, snapped = 0
        for (index, old) in clips.enumerated() {
            try Task.checkCancellation()
            let captionIndices = captions.indices.filter { captions[$0].clipID == old.id }
            if old.timingLocked == true {
                locked += 1
                if captionIndices.contains(where: { readingDuration(captions[$0].text) > captions[$0].duration + 0.1 }) { readingWarnings += 1 }
                cursor += old.duration
                continue
            }
            var duration = preferred[index]
            if beats.bpm != nil {
                let low = max(minimums[index], preferred[index] * 0.75)
                let high = min(maximums[index], max(preferred[index] * 1.28, preferred[index] + 0.8))
                if let cut = beatTimes.lazy.filter({ $0 - cursor >= low && $0 - cursor <= high })
                    .min(by: { abs(($0 - cursor) - duration) < abs(($1 - cursor) - duration) }) {
                    duration = cut - cursor
                    snapped += 1
                }
            }
            // Timeline is rendered at 30 fps; floor/ceil constraints take precedence over snapping.
            duration = min(maximums[index], max(minimums[index], (duration * 30).rounded() / 30))
            edited[index].duration = duration
            if old.kind == .video, captionIndices.isEmpty {
                let lower = old.sourceStart ?? 0
                let start = min(max(lower, content[index].bestTime - duration * 0.4), max(lower, old.sourceDuration - duration))
                edited[index].trimStart = start
                if abs(start - old.trimStart) > 0.08 { highlights += 1 }
            }
            if duration > old.duration + 0.05 { longer += 1 }
            if duration < old.duration - 0.05 { shorter += 1 }
            for captionIndex in captionIndices {
                var caption = captions[captionIndex]
                let reading = readingDuration(caption.text)
                // Photographs have no source clock. Video captions retain their source position;
                // captioned videos are never moved to a different highlight.
                let proposedStart = old.kind == .image ? caption.start * duration / old.duration : caption.start
                caption.start = max(0, min(proposedStart, max(0, duration - reading)))
                let oldDisplay = old.kind == .image ? caption.duration * duration / old.duration : caption.duration
                caption.duration = min(duration - caption.start, max(reading, oldDisplay))
                if caption.duration + 0.05 < reading { readingWarnings += 1 }
                adjustedCaptions[captionIndex] = caption
            }
            if old.kind == .image, !captionIndices.isEmpty {
                // Sequential captions must not start overlapping merely because reading time grew.
                // Originally overlapping cards remain together as one readable display interval.
                let groups = captionGroups(indices: captionIndices, captions: captions)
                var earliest = 0.0
                for (groupIndex, group) in groups.enumerated() {
                    let minimum = groupReading(group, captions: captions)
                    let future = groups.dropFirst(groupIndex + 1).reduce(0.0) { $0 + groupReading($1, captions: captions) }
                        + Double(groups.count - groupIndex - 1) * 0.12
                    let originalStart = group.map { captions[$0].start }.min() ?? 0
                    let originalEnd = group.map { captions[$0].start + captions[$0].duration }.max() ?? 0
                    let start = max(earliest, min(originalStart * duration / old.duration, duration - minimum - future))
                    let display = min(duration - start - future, max(minimum, (originalEnd - originalStart) * duration / old.duration))
                    for captionIndex in group {
                        adjustedCaptions[captionIndex].start = start
                        adjustedCaptions[captionIndex].duration = max(1.0 / 30, display)
                    }
                    earliest = start + display + 0.12
                }
            }
            cursor += duration
        }
        var summary = "画面分析完成：\(longer) 段多停留、\(shorter) 段更简洁"
        if highlights > 0 { summary += "，\(highlights) 段视频选用了更好的画面" }
        summary += "。\(musicNote)"
        if snapped > 0 { summary += " \(snapped) 个换镜点贴合实测节拍。" }
        if beats.analyzedDuration > 0, beats.fileDuration - beats.analyzedDuration > 0.1 { summary += " 节奏分析限于配乐前 \(Int(beats.analyzedDuration)) 秒。" }
        if locked > 0 { summary += " 保留 \(locked) 段手调时长。" }
        if readingWarnings > 0 { summary += " \(readingWarnings) 处原片或锁定时长较短，请复查文字阅读时间。" }
        progress(1, "自动编排已就绪。")
        return AutoEditResult(clips: edited, captions: adjustedCaptions, beatTimes: beatTimes, estimatedBPM: beats.bpm, summary: summary)
    }

    static func readingDuration(_ text: String) -> Double {
        let units = text.unicodeScalars.reduce(0.0) { count, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return count }
            if CharacterSet.punctuationCharacters.contains(scalar) { return count + 0.2 }
            return count + (scalar.value < 128 ? 0.5 : 1)
        }
        return max(1.3, units / 5.5 + 0.6)
    }

    private static func captionGroups(indices: [Int], captions: [Caption]) -> [[Int]] {
        let sorted = indices.sorted { captions[$0].start == captions[$1].start ? $0 < $1 : captions[$0].start < captions[$1].start }
        var groups: [[Int]] = []
        var end = 0.0
        for index in sorted {
            if !groups.isEmpty, captions[index].start < end - 0.000_001 {
                groups[groups.count - 1].append(index)
                end = max(end, captions[index].start + captions[index].duration)
            } else {
                groups.append([index])
                end = captions[index].start + captions[index].duration
            }
        }
        return groups
    }

    private static func groupReading(_ group: [Int], captions: [Caption]) -> Double {
        readingDuration(group.map { captions[$0].text }.joined(separator: "\n"))
    }

    private static func analyze(clip: MediaClip, mayChooseHighlight: Bool) async throws -> Content {
        try Task.checkCancellation()
        if clip.kind == .image {
            guard let image = image(url: clip.url) else { throw StudioError.message("无法分析照片“\(clip.name)”，请检查原文件。") }
            let frame = try await analyzeFrame(image, time: 0)
            return Content(score: frame.importance, bestTime: 0, feature: frame.feature)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
        let lower = clip.sourceStart ?? 0
        let room = max(1.0 / 30, clip.sourceDuration - lower)
        let count = mayChooseHighlight && clip.timingLocked != true ? min(6, max(2, Int(ceil(min(room, 12) / 2)))) : 1
        var best: Frame?
        for index in 0..<count {
            try Task.checkCancellation()
            let requested = count == 1 ? clip.trimStart + min(clip.duration * 0.45, max(0, clip.sourceDuration - clip.trimStart - 0.05))
                : lower + room * (0.08 + 0.84 * Double(index) / Double(max(1, count - 1)))
            let time = min(max(lower, requested), max(lower, clip.sourceDuration - 1.0 / 30))
            let pair = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            var frame = try await analyzeFrame(pair.image, time: pair.actualTime.seconds)
            let neighborTime = min(time + 0.35, clip.sourceDuration - 1.0 / 30)
            if neighborTime > time + 0.08 {
                let neighbor = try await withTaskCancellationHandler {
                    try await generator.image(at: CMTime(seconds: neighborTime, preferredTimescale: 600))
                } onCancel: { generator.cancelAllCGImageGeneration() }
                let next = pixels(neighbor.image)
                let difference = zip(frame.pixels.luminance, next.luminance).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(max(1, next.luminance.count))
                // Moderate local change rewards action; very large change is often a shake/cut.
                frame.motion = min(1, difference / 0.11)
                frame.importance = max(0, min(1, frame.importance + min(0.12, difference * 0.8) - max(0, difference - 0.25) * 0.7))
            }
            if best == nil || frame.importance > best!.importance { best = frame }
        }
        guard let best else { throw StudioError.message("无法读取视频“\(clip.name)”的分析画面。") }
        return Content(score: best.importance, bestTime: best.time, feature: best.feature, motion: best.motion)
    }

    private static func image(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    private static func analyzeFrame(_ image: CGImage, time: Double) async throws -> Frame {
        try Task.checkCancellation()
        let faces = VNDetectFaceRectanglesRequest()
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.revision = VNGenerateImageFeaturePrintRequestRevision1
        let requests: [VNRequest] = [faces, feature]
        // Assign only devices reported as supported by each model and compute stage.
        // CPU execution also works while the application window is in the background.
        for request in requests {
            if let stages = try? request.supportedComputeStageDevices {
                for (stage, devices) in stages {
                    if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                        request.setComputeDevice(cpu, for: stage)
                    }
                }
            }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try handler.perform(requests)
            try Task.checkCancellation()
        } onCancel: { requests.forEach { $0.cancel() } }
        let detail = pixels(image)
        let people = faces.results ?? []
        let faceArea = people.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        let portrait = min(0.24, Double(people.count) * 0.08 + sqrt(max(0, faceArea)) * 0.3)
        let composition = people.isEmpty ? detail.balance : people.map { face in
            let center = face.boundingBox.midX
            return 1 - min(abs(center - 1.0 / 3), abs(center - 2.0 / 3), abs(center - 0.5))
        }.reduce(0, +) / Double(people.count)
        let score = min(1, max(0, 0.08 + 0.43 * detail.quality + 0.30 * detail.complexity + 0.13 * composition + portrait))
        return Frame(time: time, importance: score, feature: feature.results?.first, pixels: detail)
    }

    private static func pixels(_ image: CGImage) -> Pixels {
        let side = 128
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return Pixels(luminance: [], quality: 0, complexity: 0, balance: 0) }
        var gray = [Float](repeating: 0, count: side * side)
        var histogram = [Double](repeating: 0, count: 32)
        var sum = 0.0, square = 0.0, clipped = 0.0
        for index in gray.indices {
            let start = index * 4
            let value = (0.2126 * Double(rgba[start]) + 0.7152 * Double(rgba[start + 1]) + 0.0722 * Double(rgba[start + 2])) / 255
            gray[index] = Float(value)
            sum += value; square += value * value
            histogram[min(31, Int(value * 32))] += 1
            if value < 0.025 || value > 0.975 { clipped += 1 }
        }
        let count = Double(gray.count), mean = sum / count
        let contrast = min(1, sqrt(max(0, square / count - mean * mean)) / 0.23)
        var gradient = 0.0, laplacian = 0.0, mass = 0.0, centerX = 0.0, centerY = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let edge = Double(abs(gray[i + 1] - gray[i - 1]) + abs(gray[i + side] - gray[i - side]))
                let lap = Double(gray[i - 1] + gray[i + 1] + gray[i - side] + gray[i + side] - 4 * gray[i])
                gradient += edge; laplacian += lap * lap
                mass += edge; centerX += Double(x) * edge; centerY += Double(y) * edge
            }
        }
        let sharpness = min(1, sqrt(laplacian / count) / 0.16)
        let edges = min(1, gradient / count / 0.17)
        let entropy = histogram.reduce(0.0) { total, value in
            let probability = value / count
            return probability > 0 ? total - probability * log2(probability) / 5 : total
        }
        let quality = 0.48 * sharpness + 0.27 * contrast + 0.25 * (1 - clipped / count)
        let complexity = 0.48 * entropy + 0.30 * contrast + 0.22 * edges
        let balance = mass > 0.001 ? max(0, 1 - (abs(centerX / mass / Double(side) - 0.5) + abs(centerY / mass / Double(side) - 0.5))) : 0.25
        return Pixels(luminance: gray, quality: quality, complexity: complexity, balance: balance)
    }

    /// PCM -> Hann-windowed spectral flux + positive log-energy change -> measured peaks.
    /// Tempo is accepted only when observed attacks support a stable phase and period.
    static func detectBeats(url: URL, maximumDuration: Double = 180) async throws -> BeatAnalysis {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.processingFormat.channelCount > 0, file.processingFormat.channelCount <= 64 else {
            throw StudioError.message("配乐的音频格式无法分析。")
        }
        let fileDuration = Double(file.length) / sampleRate
        let limit = min(fileDuration, max(0.1, min(180, maximumDuration)))
        let framesToRead = min(file.length, AVAudioFramePosition((limit * sampleRate).rounded(.down)))
        let targetRate = min(11025.0, sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else {
            throw StudioError.message("无法读取配乐的音频采样。")
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(limit * targetRate) + 1)
        var phase = 0.0, accumulated: Float = 0, accumulatedCount = 0
        while file.framePosition < framesToRead {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(min(32768, framesToRead - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            // Select the strongest channel per block so antiphase stereo does not cancel beats.
            var selected = 0, bestPower: Float = -1
            for channel in 0..<Int(file.processingFormat.channelCount) {
                var power: Float = 0
                for frame in stride(from: 0, to: Int(buffer.frameLength), by: 32) { power += channels[channel][frame] * channels[channel][frame] }
                if power > bestPower { bestPower = power; selected = channel }
            }
            for frame in 0..<Int(buffer.frameLength) {
                accumulated += channels[selected][frame]
                accumulatedCount += 1
                phase += targetRate
                if phase >= sampleRate {
                    mono.append(accumulated / Float(max(1, accumulatedCount)))
                    accumulated = 0; accumulatedCount = 0; phase -= sampleRate
                }
            }
        }
        try Task.checkCancellation()
        let duration = Double(mono.count) / targetRate
        guard mono.count >= 1024 else { return BeatAnalysis(times: [], bpm: nil, confidence: 0, analyzedDuration: duration, fileDuration: fileDuration) }
        let energy = mono.reduce(0.0) { $0 + Double($1 * $1) } / Double(mono.count)
        guard energy > 0.000_000_01 else { return BeatAnalysis(times: [], bpm: nil, confidence: 0, analyzedDuration: duration, fileDuration: fileDuration) }
        let windowSize = 512, hop = 128, bins = windowSize / 2
        guard let fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { throw StudioError.message("无法准备配乐节奏分析。") }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        var previous = [Float](repeating: 0, count: bins)
        var flux: [Double] = [], rise: [Double] = []
        var previousEnergy = -20.0
        var real = [Float](repeating: 0, count: bins), imaginary = real
        var frame = [Float](repeating: 0, count: windowSize)
        for start in stride(from: 0, through: mono.count - windowSize, by: hop) {
            if start.isMultiple(of: hop * 64) { try Task.checkCancellation() }
            var squared = 0.0
            for index in 0..<windowSize {
                let value = mono[start + index]
                frame[index] = value * window[index]
                squared += Double(value * value)
            }
            var novelty = 0.0
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                    for bin in 2..<bins {
                        let magnitude = sqrt(Double(r[bin] * r[bin] + im[bin] * im[bin])) / Double(windowSize)
                        novelty += max(0, magnitude - Double(previous[bin]))
                        previous[bin] = Float(magnitude)
                    }
                }
            }
            let currentEnergy = log(max(0.000_000_001, squared / Double(windowSize)))
            flux.append(novelty)
            rise.append(max(0, currentEnergy - previousEnergy))
            previousEnergy = currentEnergy
        }
        let fluxScale = percentile(flux, fraction: 0.95)
        let riseScale = percentile(rise, fraction: 0.95)
        guard flux.max() ?? 0 > 0.000_01 else { return BeatAnalysis(times: [], bpm: nil, confidence: 0, analyzedDuration: duration, fileDuration: fileDuration) }
        let values = flux.indices.map { 0.78 * flux[$0] / max(0.000_01, fluxScale) + 0.22 * rise[$0] / max(0.1, riseScale) }
        let maximum = values.max() ?? 0
        let secondsPerHop = Double(hop) / targetRate
        let neighborhood = max(3, Int(0.28 / secondsPerHop))
        var attacks: [(time: Double, strength: Double)] = []
        if values.count >= 5 {
            for index in 2..<(values.count - 2) {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                guard values[index] >= values[index - 1], values[index] > values[index + 1], values[index] > maximum * 0.055 else { continue }
                let local = Array(values[max(0, index - neighborhood)...min(values.count - 1, index + neighborhood)])
                let median = percentile(local, fraction: 0.5)
                let deviation = percentile(local.map { abs($0 - median) }, fraction: 0.5)
                guard values[index] > median + max(0.08, deviation * 1.7) else { continue }
                let time = (Double(index * hop) + Double(windowSize) / 2) / targetRate
                if let last = attacks.last, time - last.time < 0.16 {
                    if values[index] > last.strength { attacks[attacks.count - 1] = (time, values[index]) }
                } else { attacks.append((time, values[index])) }
            }
        }
        return tempo(attacks: attacks, analyzedDuration: duration, fileDuration: fileDuration)
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))]
    }

    private static func tempo(attacks: [(time: Double, strength: Double)], analyzedDuration: Double, fileDuration: Double) -> BeatAnalysis {
        let none = BeatAnalysis(times: [], bpm: nil, confidence: 0, analyzedDuration: analyzedDuration, fileDuration: fileDuration)
        guard attacks.count >= 5, let first = attacks.first, let last = attacks.last, last.time - first.time >= 2 else { return none }
        var histogram = [Double](repeating: 0, count: 121)
        let maximumStrength = attacks.map(\.strength).max() ?? 1
        for index in attacks.indices {
            for step in 1...4 where index + step < attacks.count {
                let interval = attacks[index + step].time - attacks[index].time
                guard interval >= 0.3, interval <= 1.2 else { continue }
                let weight = sqrt(max(0, attacks[index].strength * attacks[index + step].strength)) / maximumStrength / Double(step)
                let center = Int((interval * 100).rounded())
                for bin in max(30, center - 2)...min(120, center + 2) {
                    histogram[bin] += weight * max(0, 1 - abs(Double(bin) / 100 - interval) / 0.03)
                }
            }
        }
        guard let bin = (30...120).max(by: { histogram[$0] < histogram[$1] }), histogram[bin] > 0 else { return none }
        // Refine the period from measured neighboring intervals near the mode.
        let rough = Double(bin) / 100
        let intervals = zip(attacks, attacks.dropFirst()).map { $1.time - $0.time }.filter { abs($0 - rough) < 0.045 }
        let period = intervals.isEmpty ? rough : intervals.reduce(0, +) / Double(intervals.count)
        let tolerance = max(0.035, period * 0.12)
        var best: [(time: Double, strength: Double)] = [], bestWeight = 0.0
        let anchors = attacks.sorted { $0.strength > $1.strength }.prefix(24)
        for anchor in anchors {
            let matching = attacks.filter { attack in
                let cycles = ((attack.time - anchor.time) / period).rounded()
                return abs(attack.time - anchor.time - cycles * period) <= tolerance
            }
            let weight = matching.reduce(0.0) { $0 + $1.strength }
            if weight > bestWeight { bestWeight = weight; best = matching }
        }
        guard best.count >= 5 else { return none }
        let purity = bestWeight / max(0.000_001, attacks.reduce(0.0) { $0 + $1.strength })
        let coverage = min(1, Double(best.count) / max(1, (last.time - first.time) / period + 1))
        let consistency = Double(zip(best, best.dropFirst()).filter { a, b in
            let count = ((b.time - a.time) / period).rounded()
            return count >= 1 && abs(b.time - a.time - count * period) < tolerance
        }.count) / Double(max(1, best.count - 1))
        let confidence = 0.5 * purity + 0.3 * coverage + 0.2 * consistency
        guard confidence >= 0.64 else { return none }
        return BeatAnalysis(times: best.map(\.time), bpm: 60 / period, confidence: confidence,
                            analyzedDuration: analyzedDuration, fileDuration: fileDuration)
    }
}
