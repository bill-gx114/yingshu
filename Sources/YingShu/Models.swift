import AppKit
import AVFoundation
import Foundation

enum MediaKind: String, Codable { case image, video }
enum ClipOrderMode: String, Codable, CaseIterable, Identifiable {
    case chronological = "拍摄时间", story = "智能叙事", filename = "文件名", imported = "导入顺序", manual = "手动顺序"
    var id: String { rawValue }
}
enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case subtitle = "字幕", sticker = "贴纸", note = "手记", companion = "小人气泡"
    var id: String { rawValue }
}
enum VideoFormat: String, Codable, CaseIterable, Identifiable {
    case landscape = "横屏 16:9", portrait = "竖屏 9:16", square = "方形 1:1"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
    var aspect: CGFloat { size.width / size.height }
}
struct MediaClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var name: String
    var kind: MediaKind
    var duration: Double
    var sourceDuration: Double
    var trimStart: Double = 0
    var sourceStart: Double? = nil
    var timingLocked: Bool? = nil
    var capturedAt: Date? = nil
    var fileCreatedAt: Date? = nil
    var importOrder: Int? = nil
    var livePhotoStillURL: URL? = nil
    var livePhotoAssetID: String? = nil
}
struct Caption: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var clipID: UUID
    var start: Double
    var duration: Double
    var text: String
    var style: CaptionStyle = .subtitle
    /// Recognition text before any later editing; absent for older/written captions.
    var originalTranscript: String? = nil
}
struct MusicTrack: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var url: URL
    var license: String
}
struct DownloadedMusic: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var artist: String
    var localURL: URL
    var sourceURL: URL
    var license: String
    var licenseURL: URL
    var attribution: String
}
struct ProjectDocument: Codable, Equatable {
    var version: Int = 1
    var title: String
    var clips: [MediaClip]
    var captions: [Caption]
    var format: VideoFormat
    var musicID: String?
    var customMusicURL: URL?
    var musicVolume: Double
    var automaticEditEnabled: Bool? = nil
    var orderMode: ClipOrderMode? = nil
    var downloadedMusic: [DownloadedMusic]? = nil
    var speechMode: SpeechRecognitionMode? = nil
    var speechVocabulary: [String]? = nil
    /// Written only in the local recovery copy, never in a shared project file.
    var recoveryProjectURL: URL? = nil
}
enum RecoverySaveState: Equatable {
    case idle, pending, saved(Date), failed(String), disabled
}
enum ProjectAssetKind: String {
    case image = "照片", video = "视频", livePhoto = "实况照片", music = "配乐"
}
struct MissingProjectAsset: Identifiable, Equatable {
    var id: String
    var url: URL
    var label: String
    var kind: ProjectAssetKind
    var clipID: UUID? = nil
}
struct StoryOrderResult { var clips: [MediaClip]; var summary: String }
struct AutoEditResult {
    var clips: [MediaClip]
    var captions: [Caption]
    var beatTimes: [Double]
    var estimatedBPM: Double?
    var summary: String
}
struct ExportSettings {
    var clips: [MediaClip]
    var captions: [Caption]
    var format: VideoFormat
    var musicURL: URL?
    var musicVolume: Double
    var outputURL: URL
}
enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
func timeLabel(_ seconds: Double) -> String {
    let n = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d", n / 60, n % 60)
}
extension Array where Element == MediaClip {
    var totalDuration: Double { reduce(0) { $0 + $1.duration } }
    func startTime(of id: UUID) -> Double {
        var time = 0.0
        for clip in self { if clip.id == id { return time }; time += clip.duration }
        return time
    }
    func location(at time: Double) -> (clip: MediaClip, offset: Double)? {
        var start = 0.0
        for (index, clip) in enumerated() {
            if time < start + clip.duration || index == count - 1 {
                return (clip, Swift.max(0, Swift.min(clip.duration, time - start)))
            }
            start += clip.duration
        }
        return nil
    }
}
