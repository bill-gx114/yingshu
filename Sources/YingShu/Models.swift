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
enum CompanionSkinTone: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cream, peach, honey, cocoa, deep
    var id: String { rawValue }
    var label: String {
        switch self { case .cream: return "奶油"; case .peach: return "蜜桃"; case .honey: return "暖蜜"; case .cocoa: return "可可"; case .deep: return "浓巧" }
    }
    var color: NSColor {
        switch self {
        case .cream: return NSColor(srgbRed: 0.96, green: 0.82, blue: 0.65, alpha: 1)
        case .peach: return NSColor(srgbRed: 0.91, green: 0.66, blue: 0.51, alpha: 1)
        case .honey: return NSColor(srgbRed: 0.76, green: 0.52, blue: 0.32, alpha: 1)
        case .cocoa: return NSColor(srgbRed: 0.54, green: 0.34, blue: 0.23, alpha: 1)
        case .deep: return NSColor(srgbRed: 0.34, green: 0.22, blue: 0.18, alpha: 1)
        }
    }
}
enum CompanionHairStyle: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case bucketHat, short, bob, curls, bun, bald
    var id: String { rawValue }
    var label: String {
        switch self { case .bucketHat: return "渔夫帽"; case .short: return "短发"; case .bob: return "波波头"; case .curls: return "卷卷发"; case .bun: return "丸子头"; case .bald: return "光头" }
    }
}
enum CompanionHairColor: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case espresso, chestnut, honey, silver
    var id: String { rawValue }
    var label: String {
        switch self { case .espresso: return "浓咖"; case .chestnut: return "栗棕"; case .honey: return "蜜金"; case .silver: return "银灰" }
    }
    var color: NSColor {
        switch self {
        case .espresso: return NSColor(srgbRed: 0.21, green: 0.18, blue: 0.17, alpha: 1)
        case .chestnut: return NSColor(srgbRed: 0.43, green: 0.27, blue: 0.19, alpha: 1)
        case .honey: return NSColor(srgbRed: 0.77, green: 0.55, blue: 0.29, alpha: 1)
        case .silver: return NSColor(srgbRed: 0.66, green: 0.68, blue: 0.66, alpha: 1)
        }
    }
}
enum CompanionFaceShape: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case round, oval, softSquare
    var id: String { rawValue }
    var label: String {
        switch self { case .round: return "圆圆脸"; case .oval: return "鹅蛋脸"; case .softSquare: return "小方脸" }
    }
}
enum CompanionOutfitColor: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case coral, sage, ocean, lavender, oat, charcoal
    var id: String { rawValue }
    var label: String {
        switch self { case .coral: return "珊瑚"; case .sage: return "鼠尾草"; case .ocean: return "海蓝"; case .lavender: return "雾紫"; case .oat: return "燕麦"; case .charcoal: return "炭灰" }
    }
    var color: NSColor {
        switch self {
        case .coral: return NSColor(srgbRed: 0.86, green: 0.39, blue: 0.29, alpha: 1)
        case .sage: return NSColor(srgbRed: 0.44, green: 0.57, blue: 0.43, alpha: 1)
        case .ocean: return NSColor(srgbRed: 0.30, green: 0.50, blue: 0.64, alpha: 1)
        case .lavender: return NSColor(srgbRed: 0.62, green: 0.51, blue: 0.69, alpha: 1)
        case .oat: return NSColor(srgbRed: 0.76, green: 0.65, blue: 0.48, alpha: 1)
        case .charcoal: return NSColor(srgbRed: 0.27, green: 0.31, blue: 0.32, alpha: 1)
        }
    }
}
enum CompanionGlassesStyle: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none, round, square
    var id: String { rawValue }
    var label: String {
        switch self { case .none: return "不戴眼镜"; case .round: return "圆框"; case .square: return "方框" }
    }
}
/// A few deliberately broad clay expressions, rather than a face mesh or the
/// measurements of a photograph. The source image never belongs to this model.
enum CompanionEyeShape: String, Codable, Hashable, Sendable { case soft, bright, smiling }
enum CompanionEyeSpacing: String, Codable, Hashable, Sendable { case close, balanced, wide }
enum CompanionSmile: String, Codable, Hashable, Sendable { case subtle, gentle, sunny }
struct CompanionPortraitTraits: Codable, Equatable, Hashable, Sendable {
    var eyeShape: CompanionEyeShape = .soft
    var eyeSpacing: CompanionEyeSpacing = .balanced
    var smile: CompanionSmile = .gentle

    static let standard = CompanionPortraitTraits()
    var visualKey: String { [eyeShape.rawValue, eyeSpacing.rawValue, smile.rawValue].joined(separator: ":") }
    init(eyeShape: CompanionEyeShape = .soft, eyeSpacing: CompanionEyeSpacing = .balanced, smile: CompanionSmile = .gentle) {
        self.eyeShape = eyeShape; self.eyeSpacing = eyeSpacing; self.smile = smile
    }
    private enum CodingKeys: String, CodingKey { case eyeShape, eyeSpacing, smile }
    init(from decoder: Decoder) throws {
        self.init()
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        eyeShape = (try? fields.decode(CompanionEyeShape.self, forKey: .eyeShape)) ?? .soft
        eyeSpacing = (try? fields.decode(CompanionEyeSpacing.self, forKey: .eyeSpacing)) ?? .balanced
        smile = (try? fields.decode(CompanionSmile.self, forKey: .smile)) ?? .gentle
    }
}
struct CompanionProfile: Codable, Equatable, Hashable, Sendable {
    var name: String = ""
    var skinTone: CompanionSkinTone = .cream
    var hairStyle: CompanionHairStyle = .bucketHat
    var hairColor: CompanionHairColor = .espresso
    var faceShape: CompanionFaceShape = .round
    var outfitColor: CompanionOutfitColor = .coral
    var glassesStyle: CompanionGlassesStyle = .none
    var portraitTraits: CompanionPortraitTraits? = nil

    static let classic = CompanionProfile()
    var displayName: String { let value = normalized().name; return value.isEmpty ? "我的小旅伴" : value }
    /// Stable renderer identity deliberately excludes the display-only nickname.
    var visualKey: String {
        let base = [skinTone.rawValue, hairStyle.rawValue, hairColor.rawValue, faceShape.rawValue, outfitColor.rawValue, glassesStyle.rawValue].joined(separator: "|")
        guard let traits = portraitTraits, traits != .standard else { return base }
        return base + "|portrait:" + traits.visualKey
    }
    var isClassicAppearance: Bool { visualKey == Self.classic.visualKey }
    func normalized() -> Self {
        var value = self
        value.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        if value.portraitTraits == .standard { value.portraitTraits = nil }
        return value
    }
    private enum CodingKeys: String, CodingKey { case name, skinTone, hairStyle, hairColor, faceShape, outfitColor, glassesStyle, portraitTraits }
    init(name: String = "", skinTone: CompanionSkinTone = .cream, hairStyle: CompanionHairStyle = .bucketHat,
         hairColor: CompanionHairColor = .espresso, faceShape: CompanionFaceShape = .round,
         outfitColor: CompanionOutfitColor = .coral, glassesStyle: CompanionGlassesStyle = .none,
         portraitTraits: CompanionPortraitTraits? = nil) {
        self.name = name; self.skinTone = skinTone; self.hairStyle = hairStyle; self.hairColor = hairColor
        self.faceShape = faceShape; self.outfitColor = outfitColor; self.glassesStyle = glassesStyle
        self.portraitTraits = portraitTraits == .standard ? nil : portraitTraits
    }
    init(from decoder: Decoder) throws {
        self.init()
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        name = (try? fields.decode(String.self, forKey: .name)) ?? ""
        skinTone = (try? fields.decode(CompanionSkinTone.self, forKey: .skinTone)) ?? .cream
        hairStyle = (try? fields.decode(CompanionHairStyle.self, forKey: .hairStyle)) ?? .bucketHat
        hairColor = (try? fields.decode(CompanionHairColor.self, forKey: .hairColor)) ?? .espresso
        faceShape = (try? fields.decode(CompanionFaceShape.self, forKey: .faceShape)) ?? .round
        outfitColor = (try? fields.decode(CompanionOutfitColor.self, forKey: .outfitColor)) ?? .coral
        glassesStyle = (try? fields.decode(CompanionGlassesStyle.self, forKey: .glassesStyle)) ?? .none
        portraitTraits = try? fields.decode(CompanionPortraitTraits.self, forKey: .portraitTraits)
        self = normalized()
    }
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
    /// Absent in older projects; their established appearance stays classic.
    var companionProfile: CompanionProfile? = nil
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
    var companionProfile: CompanionProfile = .classic
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
