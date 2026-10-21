import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A temporary suggestion only. The source photo and biometric landmarks are never
/// added to the profile, project document, recovery file, or an on-disk cache.
struct CompanionPhotoDraft: Sendable {
    let profile: CompanionProfile
    let summary: String
}

enum CompanionPhotoError: LocalizedError, Equatable {
    case unsupportedImage, unreadableImage, fileTooLarge, imageTooLarge
    case noFace, multipleFaces, faceTooSmall, faceTurned, unclearFace
    var errorDescription: String? {
        switch self {
        case .unsupportedImage: return "请选一张 JPEG、PNG 或 HEIC 照片。"
        case .unreadableImage: return "这张照片暂时读不了，请换一张清楚的单人正面照。"
        case .fileTooLarge: return "照片超过 40 MB，请先缩小文件后再试。"
        case .imageTooLarge: return "照片尺寸过大，请先缩小到一亿像素以内再试。"
        case .noFace: return "没有找到清楚的人脸。试试光线均匀、脸部无遮挡的单人正面照。"
        case .multipleFaces: return "照片里有不止一个人。请先裁出你想参考的那个人，再重新选择。"
        case .faceTooSmall: return "脸部在照片里太小了。请裁近一些，保留头顶和肩膀再试。"
        case .faceTurned: return "这张照片的脸转得有点多。请换一张接近正面、头部摆正的照片。"
        case .unclearFace: return "五官还不够清楚。请换一张脸部无遮挡、光线更均匀的正面照。"
        }
    }
}

/// Uses Apple's bundled Vision detector; no model download, account or network call.
/// Deliberately suggests a few soft toy proportions, never a photorealistic likeness.
enum CompanionPhotoAnalyzer {
    static let maximumFileBytes = 40 * 1024 * 1024
    static let maximumSourcePixels = 100_000_000
    static let maximumSourceSide = 30_000
    static let maximumThumbnailSide = 1_600

    static func analyze(url: URL, startingFrom profile: CompanionProfile = .classic) async throws -> CompanionPhotoDraft {
        try Task.checkCancellation()
        let cancellation = PhotoAnalysisCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let image = try decodeImage(url: url, cancellation: cancellation)
                try cancellation.check()
                let request = VNDetectFaceLandmarksRequest()
                request.preferBackgroundProcessing = true
                request.revision = VNDetectFaceLandmarksRequestRevision3
                cancellation.register(request)
                do {
                    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
                } catch {
                    try cancellation.check()
                    throw CompanionPhotoError.unclearFace
                }
                try cancellation.check()
                let faces = request.results ?? []
                guard !faces.isEmpty else { throw CompanionPhotoError.noFace }
                guard faces.count == 1 else { throw CompanionPhotoError.multipleFaces }
                let face = faces[0]
                guard face.boundingBox.width * Double(image.width) >= 90,
                      face.boundingBox.height * Double(image.height) >= 90,
                      face.boundingBox.width >= 0.09 else { throw CompanionPhotoError.faceTooSmall }
                guard abs(face.yaw?.doubleValue ?? 0) <= 0.42,
                      abs(face.roll?.doubleValue ?? 0) <= 0.34,
                      abs(face.pitch?.doubleValue ?? 0) <= 0.42 else { throw CompanionPhotoError.faceTurned }
                guard let landmarks = face.landmarks, landmarks.confidence >= 0.25,
                      let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
                      leftEye.pointCount >= 4, rightEye.pointCount >= 4,
                      let mouth = landmarks.outerLips, mouth.pointCount >= 4 else {
                    throw CompanionPhotoError.unclearFace
                }
                let sample = CompanionPhotoFaceSample(
                    bounds: face.boundingBox,
                    contour: points(landmarks.faceContour),
                    leftEye: points(leftEye), rightEye: points(rightEye), lips: points(mouth))
                let result = try makeDraft(image: image, face: sample, startingFrom: profile)
                try cancellation.check()
                return result
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    /// Bound compressed input before ImageIO sees it, then decode only an oriented
    /// thumbnail. Snapshotting also avoids a source file changing between checks.
    static func decodeImage(url: URL) throws -> CGImage {
        try decodeImage(url: url, cancellation: PhotoAnalysisCancellation())
    }
    private static func decodeImage(url: URL, cancellation: PhotoAnalysisCancellation) throws -> CGImage {
        guard url.isFileURL else { throw CompanionPhotoError.unreadableImage }
        try cancellation.check()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw CompanionPhotoError.unreadableImage }
        guard let size = values.fileSize, size > 0 else { throw CompanionPhotoError.unreadableImage }
        guard size <= maximumFileBytes else { throw CompanionPhotoError.fileTooLarge }
        guard let stream = InputStream(url: url) else { throw CompanionPhotoError.unreadableImage }
        stream.open(); defer { stream.close() }
        var data = Data(); data.reserveCapacity(min(size, maximumFileBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CompanionPhotoError.unreadableImage }
            if count == 0 { break }
            guard data.count + count <= maximumFileBytes else { throw CompanionPhotoError.fileTooLarge }
            data.append(contentsOf: buffer[0..<count])
        }
        try cancellation.check()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              [UTType.jpeg, .png, .heic, .heif].contains(where: { type.conforms(to: $0) }) else {
            throw CompanionPhotoError.unsupportedImage
        }
        let count = CGImageSourceGetCount(source)
        let isHEIF = type.conforms(to: .heic) || type.conforms(to: .heif)
        guard count > 0, isHEIF || count == 1 else { throw CompanionPhotoError.unsupportedImage }
        // iPhone HEIF containers may include more than one image. ImageIO's
        // declared primary photo is the intended image, not an arbitrary frame.
        let imageIndex = isHEIF ? CGImageSourceGetPrimaryImageIndex(source) : 0
        guard imageIndex < count,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, imageIndex, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw CompanionPhotoError.unreadableImage }
        guard width <= maximumSourceSide, height <= maximumSourceSide,
              width <= maximumSourcePixels / height else { throw CompanionPhotoError.imageTooLarge }
        try cancellation.check()
        if isHEIF && count > 1 {
            // On some ImageIO versions CreateThumbnailAtIndex can return the
            // first HEIF image despite a different requested primary index.
            // Direct indexed decoding honours it; codec subsampling and a final
            // bounded Core Image render keep the analysis image small.
            let longestSide = max(width, height)
            let factor = longestSide > maximumThumbnailSide * 4 ? 8 : (longestSide > maximumThumbnailSide * 2 ? 4 : (longestSide > maximumThumbnailSide ? 2 : 1))
            guard let primary = CGImageSourceCreateImageAtIndex(source, imageIndex,
                [kCGImageSourceShouldCache: false, kCGImageSourceSubsampleFactor: factor] as CFDictionary) else {
                throw CompanionPhotoError.unreadableImage
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            let oriented = CIImage(cgImage: primary).oriented(forExifOrientation: (1...8).contains(orientation) ? orientation : 1)
            let scale = min(1, Double(maximumThumbnailSide) / max(oriented.extent.width, oriented.extent.height))
            let small = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            try cancellation.check()
            guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(small, from: small.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                  image.width > 0, image.height > 0,
                  image.width <= maximumThumbnailSide, image.height <= maximumThumbnailSide else {
                throw CompanionPhotoError.unreadableImage
            }
            try cancellation.check()
            return image
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailSide,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= maximumThumbnailSide, image.height <= maximumThumbnailSide else {
            throw CompanionPhotoError.unreadableImage
        }
        try cancellation.check()
        return image
    }

    private static func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
        guard let region else { return [] }
        return Array(region.normalizedPoints)
    }

    /// Internal deterministic seam: synthetic colour swatches and injected landmark
    /// geometry test the mapping without pretending a drawing tests face detection.
    static func makeDraft(image: CGImage, face: CompanionPhotoFaceSample, startingFrom original: CompanionProfile) throws -> CompanionPhotoDraft {
        let raster = try CompanionPhotoRaster(image: image)
        var profile = original.normalized()
        if profile.hairStyle == .bucketHat { profile.hairStyle = .short }
        let faceBounds = face.bounds
        func region(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: faceBounds.minX + x * faceBounds.width, y: faceBounds.minY + y * faceBounds.height,
                   width: width * faceBounds.width, height: height * faceBounds.height)
        }
        // Cheeks are away from eyes/lips. A median ignores a few highlights and
        // small shadows instead of applying a skin-colour or demographic classifier.
        let cheeks = raster.colors(in: [region(0.18, 0.28, 0.20, 0.17), region(0.62, 0.28, 0.20, 0.17)])
        guard let skin = CompanionPhotoRGB.robustMedian(cheeks), cheeks.count >= 18 else { throw CompanionPhotoError.unclearFace }
        profile.skinTone = nearest(skin, choices: CompanionSkinTone.allCases, color: { $0.color })

        // The clothing region deliberately avoids the chin. Out-of-frame or very
        // varied backgrounds leave the user's existing colour alone.
        let clothing = raster.colors(in: [region(0.08, -1.02, 0.84, 0.40)])
        if let dominant = CompanionPhotoRGB.dominant(clothing), clothing.count >= 24 {
            profile.outfitColor = nearest(dominant, choices: CompanionOutfitColor.allCases, color: { $0.color })
        }
        // Hair colour is a gentle suggestion only; hairstyle, hat and glasses are
        // preserved. Reject skin-like samples and high-variance backgrounds.
        let hair = raster.colors(in: [region(0.20, 0.94, 0.60, 0.19), region(0.04, 0.63, 0.09, 0.30), region(0.87, 0.63, 0.09, 0.30)])
            .filter { $0.distance(to: skin) > 0.006 && ($0.saturation < 0.28 || ($0.red >= $0.green * 0.95 && $0.red >= $0.blue * 0.95)) }
        if let dominant = CompanionPhotoRGB.dominant(hair), hair.count >= 18 {
            let choice = nearest(dominant, choices: CompanionHairColor.allCases, color: { $0.color })
            if dominant.distance(to: CompanionPhotoRGB(choice.color)) < 0.045 { profile.hairColor = choice }
        }
        // Correct for the actual face crop aspect ratio before measuring features.
        let aspect = (faceBounds.width * CGFloat(image.width)) / max(1, faceBounds.height * CGFloat(image.height))
        func adjusted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * aspect, y: point.y) }
        let left = face.leftEye.map(adjusted), right = face.rightEye.map(adjusted)
        let lips = face.lips.map(adjusted), contour = face.contour.map(adjusted)
        let leftBox = bounds(left), rightBox = bounds(right), lipBox = bounds(lips)
        guard leftBox.width > 0.01, rightBox.width > 0.01, lipBox.width > 0.01 else { throw CompanionPhotoError.unclearFace }
        let eyeOpening = (leftBox.height / leftBox.width + rightBox.height / rightBox.width) / 2
        let eyeSpacing = abs(leftBox.midX - rightBox.midX) / max(0.1, aspect)
        let mouthWidth = lipBox.width / max(0.1, aspect)
        let traits = CompanionPortraitTraits(
            eyeShape: eyeOpening < 0.16 ? .smiling : (eyeOpening > 0.32 ? .bright : .soft),
            eyeSpacing: eyeSpacing < 0.37 ? .close : (eyeSpacing > 0.49 ? .wide : .balanced),
            smile: mouthWidth < 0.34 ? .subtle : (mouthWidth > 0.47 ? .sunny : .gentle))
        profile.portraitTraits = traits
        if contour.count >= 8 {
            // Only a coarse, softened face silhouette is retained.
            let contourBox = bounds(contour)
            let ratio = contourBox.width / max(0.1, contourBox.height)
            let lower = contour.filter { $0.y < contourBox.minY + contourBox.height * 0.30 }
            let jawRatio = bounds(lower).width / max(0.1, contourBox.width)
            profile.faceShape = ratio < 1.02 ? .oval : (jawRatio > 0.76 ? .softSquare : .round)
        }
        profile = profile.normalized()
        return CompanionPhotoDraft(profile: profile,
            summary: "已参考脸部轮廓、眼神和配色，做成更柔和的黏土草稿。发型和眼镜还可以自己选，光线或背景影响的颜色也可以再调。")
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            CGRect(x: min(result.minX, point.x), y: min(result.minY, point.y),
                   width: max(result.maxX, point.x) - min(result.minX, point.x),
                   height: max(result.maxY, point.y) - min(result.minY, point.y))
        }
    }
    private static func nearest<T>(_ sample: CompanionPhotoRGB, choices: [T], color: (T) -> NSColor) -> T {
        choices.min { sample.distance(to: CompanionPhotoRGB(color($0))) < sample.distance(to: CompanionPhotoRGB(color($1))) }!
    }
}

struct CompanionPhotoFaceSample: Sendable {
    let bounds: CGRect
    let contour: [CGPoint]
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]
    let lips: [CGPoint]
}

private final class PhotoAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
    func register(_ value: VNRequest) {
        lock.lock(); request = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = request; lock.unlock()
        value?.cancel()
    }
}

struct CompanionPhotoRGB {
    let red: Double, green: Double, blue: Double
    init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: NSColor) {
        let color = color.usingColorSpace(.sRGB) ?? color
        self.init(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }
    var luminance: Double { red * 0.2126 + green * 0.7152 + blue * 0.0722 }
    var saturation: Double { let high = max(red, green, blue); return high > 0 ? (high - min(red, green, blue)) / high : 0 }
    func distance(to other: Self) -> Double {
        let lightness = luminance - other.luminance
        let redChroma = (red - green) - (other.red - other.green)
        let blueChroma = (blue - green) - (other.blue - other.green)
        return lightness * lightness * 2 + redChroma * redChroma * 0.7 + blueChroma * blueChroma * 0.7
    }
    static func robustMedian(_ colors: [Self]) -> Self? {
        guard !colors.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        return Self(median(colors.map(\.red)), median(colors.map(\.green)), median(colors.map(\.blue)))
    }
    static func dominant(_ colors: [Self]) -> Self? {
        guard colors.count >= 18 else { return nil }
        // Coarse bins favour an actual large colour area over a mean of skin,
        // background and clothing. Fail open to manual controls when ambiguous.
        let groups = Dictionary(grouping: colors) { color in
            Int(color.red * 5).clamped(to: 0...4) * 25 + Int(color.green * 5).clamped(to: 0...4) * 5 + Int(color.blue * 5).clamped(to: 0...4)
        }
        guard let winner = groups.values.max(by: { $0.count < $1.count }),
              Double(winner.count) / Double(colors.count) >= 0.28 else { return nil }
        return robustMedian(winner)
    }
}

struct CompanionPhotoRaster {
    let width: Int, height: Int
    private let bytes: [UInt8]
    init(image: CGImage) throws {
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw CompanionPhotoError.unreadableImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }
    /// Vision normalized coordinates are measured from the bottom left; CGImage
    /// byte rows are top-down. This conversion is covered by directional tests.
    func colors(in regions: [CGRect]) -> [CompanionPhotoRGB] {
        var result: [CompanionPhotoRGB] = []
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        for region in regions {
            let rect = region.intersection(full)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            let minX = max(0, min(width - 1, Int(rect.minX * Double(width))))
            let maxX = max(minX + 1, min(width, Int(ceil(rect.maxX * Double(width)))))
            let minY = max(0, min(height - 1, Int((1 - rect.maxY) * Double(height))))
            let maxY = max(minY + 1, min(height, Int(ceil((1 - rect.minY) * Double(height)))))
            let step = max(1, Int(sqrt(Double((maxX - minX) * (maxY - minY)) / 900)))
            for y in stride(from: minY, to: maxY, by: step) {
                for x in stride(from: minX, to: maxX, by: step) {
                    let index = (y * width + x) * 4
                    let alpha = Double(bytes[index + 3]) / 255
                    guard alpha >= 0.85 else { continue }
                    result.append(CompanionPhotoRGB(min(1, Double(bytes[index]) / 255 / alpha),
                        min(1, Double(bytes[index + 1]) / 255 / alpha), min(1, Double(bytes[index + 2]) / 255 / alpha)))
                }
            }
        }
        return result
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
