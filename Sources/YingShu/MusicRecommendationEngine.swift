import AppKit
import AVFoundation
import Foundation
import Vision

struct MusicRecommendation: Equatable {
    var summary: String
    var queries: [String]
}

/// Reads a small, evenly spaced sample locally. Only the resulting mood query goes online.
enum MusicRecommendationEngine {
    static func analyze(clips: [MediaClip], captions: [Caption]) async throws -> MusicRecommendation {
        let work = Task.detached(priority: .utility) {
            var scores: [String: Float] = [:]
            var analyzed = 0
            let count = min(12, clips.count)
            for sample in 0..<count {
                try Task.checkCancellation()
                let index = count <= 1 ? 0 : sample * (clips.count - 1) / (count - 1)
                let clip = clips[index]
                guard let image = await MediaEngine.thumbnail(for: clip),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let request = VNClassifyImageRequest()
                do {
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    analyzed += 1
                    for observation in (request.results ?? []).prefix(16) where observation.confidence > 0.08 {
                        scores[observation.identifier.lowercased(), default: 0] += observation.confidence
                    }
                } catch { if Task.isCancelled { throw CancellationError() } }
            }
            try Task.checkCancellation()
            return recommendation(scores: scores, captions: captions.map(\.text).joined(separator: " "),
                                  averageDuration: clips.isEmpty ? 4 : clips.totalDuration / Double(clips.count), analyzed: analyzed)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    static func recommendation(scores: [String: Float], captions: String, averageDuration: Double, analyzed: Int) -> MusicRecommendation {
        let scenes: [(String, [String], [String], [String])] = [
            ("海边与水景", ["beach", "coast", "ocean", "sea", "water", "lake", "river"], ["海边", "海风", "海浪", "湖", "河"], ["海边氛围", "轻柔钢琴", "清新民谣"]),
            ("山野与自然", ["mountain", "forest", "nature", "tree", "park", "flower", "outdoor", "landscape"], ["山", "踏青", "森林", "公园", "春天"], ["清新民谣", "轻柔钢琴", "自然氛围"]),
            ("城市与旅途", ["city", "street", "building", "architecture", "train", "vehicle", "urban"], ["城市", "街头", "列车", "旅行"], ["轻快旅行", "氛围电子", "温暖爵士"]),
            ("人物与相聚", ["people", "person", "portrait", "family", "face", "food", "dining"], ["朋友", "家人", "一起", "生日", "聚会"], ["温暖爵士", "清新民谣", "轻柔钢琴"]),
            ("夜色与回忆", ["night", "sunset", "dusk", "moon", "evening"], ["夜", "傍晚", "日落", "回忆", "想念"], ["夜晚氛围", "轻柔钢琴", "氛围电子"])
        ]
        var ranked: [(String, [String], Float)] = []
        for scene in scenes {
            var visual: Float = 0
            for (identifier, score) in scores where scene.1.contains(where: { identifier.contains($0) }) { visual += score }
            let words = Float(scene.2.filter { captions.contains($0) }.count) * 0.8
            ranked.append((scene.0, scene.3, visual + words))
        }
        ranked.sort { left, right in left.2 == right.2 ? left.0 < right.0 : left.2 > right.2 }
        if let best = ranked.first, best.2 > 0 {
            var queries = best.1
            if averageDuration < 3 { queries[2] = "轻快旅行" }
            let basis = analyzed > 0 ? "结合\(analyzed)段本机画面分析与感想" : "结合已有感想"
            return MusicRecommendation(summary: "\(basis)，偏向\(best.0)，可试试这些配乐。", queries: queries)
        }
        return MusicRecommendation(summary: analyzed > 0 ? "画面没有明显的单一主题，先推荐适合旅行手记的轻音乐。" : "暂未读取到足够画面，先推荐通用轻音乐，也可以输入自己的想法。", queries: ["轻柔钢琴", "清新民谣", "氛围电子"])
    }

    static func searchQuery(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapping = [("轻柔钢琴", "piano"), ("清新民谣", "acoustic"), ("海边氛围", "ambient"),
                       ("自然氛围", "ambient"), ("轻快旅行", "upbeat"), ("温暖爵士", "jazz"),
                       ("夜晚氛围", "chill"), ("氛围电子", "electronic"), ("钢琴", "piano"),
                       ("民谣", "acoustic"), ("轻音乐", "instrumental"), ("爵士", "jazz"),
                       ("吉他", "guitar"), ("治愈", "peaceful"), ("轻快", "upbeat"), ("安静", "calm"),
                       ("电子", "electronic"), ("氛围", "ambient")]
        if let exact = mapping.first(where: { trimmed == $0.0 }) { return exact.1 }
        var words: [String] = []
        for (phrase, word) in mapping where trimmed.contains(phrase) && !words.contains(word) { words.append(word) }
        return words.isEmpty ? trimmed : words.prefix(3).joined(separator: " ")
    }
}
