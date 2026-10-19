import Foundation

enum SpeechRecognitionMode: String, Codable, CaseIterable, Sendable {
    case localAI
    case localFirst
    case systemService
}

/// Snapshot the vocabulary before a session starts. Never change a running recognizer's context.
struct SpeechRecognitionOptions: Equatable, Sendable {
    let mode: SpeechRecognitionMode
    let contextualStrings: [String]

    init(mode: SpeechRecognitionMode = .localFirst, contextualStrings: [String] = []) {
        self.mode = mode
        var seen = Set<String>()
        self.contextualStrings = contextualStrings.compactMap { value in
            let phrase = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.count <= 64,
                  seen.insert(phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh-CN"))).inserted else { return nil }
            return phrase
        }.prefix(100).map { $0 }
    }
}

enum EnhancedSpeechModelAvailability: Equatable, Sendable {
    case checking
    case unavailable(String)
    case notInstalled
    case installed
    case downloading

    var message: String {
        switch self {
        case .checking: return "正在检查增强中文识别模型…"
        case .unavailable(let reason): return reason
        case .notInstalled: return "增强中文模型尚未安装；当前使用兼容本机识别。可主动下载增强模型。"
        case .installed: return "增强中文模型已安装，口述将优先使用新版本机识别。"
        case .downloading: return "正在下载增强中文识别模型…"
        }
    }
    var canPrepare: Bool { if case .notInstalled = self { return true }; return false }
    var isDownloading: Bool { if case .downloading = self { return true }; return false }
}

enum SpeechRecognitionFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
